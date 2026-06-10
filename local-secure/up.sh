#!/usr/bin/env bash
# Spin up a work sandbox on a local k3s cluster (via k3d), behind a single boundary
# gateway container that ALL traffic flows through (egress allowlist + DNS
# filtering + GitHub/Anthropic credential injection). Idempotent.
#
# Multi-instance: pass --name NAME to run several side by side. Each instance is
# a separate cluster + gateway + state dir + docker networks + host ports, so
# they never collide. Default name is "work" (preserves the original config).
set -euo pipefail
cd "$(dirname "$0")"

# --- args --------------------------------------------------------------------
IMAGE_TAG_OVERRIDE=""
NAME="work"
REBUILD_GATEWAY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)            NAME="${2:?--name needs a value}"; shift 2;;
    --tag|--image-tag) IMAGE_TAG_OVERRIDE="${2:?--tag needs a value}"; shift 2;;
    --latest)          IMAGE_TAG_OVERRIDE="latest"; shift;;
    --rebuild-gateway) REBUILD_GATEWAY=1; shift;;
    -h|--help)
      cat <<'EOF'
Usage: ./up.sh [--name NAME] [--tag <image-tag> | --latest] [--rebuild-gateway]
  --name NAME         instance name (default: work). Each name = a separate
                      cluster/gateway/state/ports. Use a new name to test without
                      touching an existing instance.
  --tag / --latest    code-server image tag (default: current git short SHA).
  --rebuild-gateway   force rebuild + recreate the gateway container (otherwise a
                      running gateway is left up; only its allowlist is refreshed).
EOF
      exit 0;;
    *) echo "Unknown arg: $1 (see --help)"; exit 1;;
  esac
done

# instance name must be a DNS-ish label (used in cluster/network/container names)
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || {
  echo "Invalid --name '$NAME' (use lowercase letters/digits/'-', start alnum, <=31 chars)"; exit 1; }

# --- load per-person config -------------------------------------------------
[[ -f .env ]] && { set -a; . ./.env; set +a; }

# --- derive per-instance identifiers ----------------------------------------
CLUSTER="code-server-${NAME}"
NODE="k3d-${CLUSTER}-server-0"   # k3d prefixes node containers with k3d-…-server-N
NET_INTERNAL="cs-${NAME}-internal"
NET_EGRESS="cs-${NAME}-egress"
GW_NAME="cs-${NAME}-gateway"
GW_IMAGE="cs-gateway:local"
# "work" keeps the original subnet/ports; other names derive a unique octet+ports
# from a stable hash so multiple instances don't clash.
if [[ "$NAME" == "work" ]]; then
  OCTET=0; VSCODE_PORT="${VSCODE_PORT:-4444}"; TTYD_PORT="${TTYD_PORT:-7681}"; API_PORT="${API_PORT:-6443}"
else
  OCTET=$(( $(printf '%s' "$NAME" | cksum | cut -d' ' -f1) % 250 + 1 ))
  VSCODE_PORT="${VSCODE_PORT:-$((4444 + OCTET))}"
  TTYD_PORT="${TTYD_PORT:-$((7681 + OCTET))}"
  API_PORT="${API_PORT:-$((6443 + OCTET))}"
fi
SUBNET="172.30.${OCTET}.0/24"
GW_IP="172.30.${OCTET}.2"
# NO_PROXY for the k3s node's HTTP(S)_PROXY (set in the k3d config): keep cluster +
# internal traffic direct. 10.0.0.0/8 covers k3s pod (10.42/16) + svc (10.43/16)
# CIDRs; 172.16.0.0/12 covers the node net; the apiserver is on loopback.
NO_PROXY_VAL="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,.svc,.cluster.local"

# State dir per instance (so instances never share Claude auth/state). A .env
# STATE_DIR is honoured only for the default "work" instance (back-compat).
if [[ "$NAME" == "work" && -n "${STATE_DIR:-}" ]]; then :; else
  STATE_DIR="$HOME/.code-server-${NAME}/state"
fi

echo "==> Instance: $NAME  (cluster=$CLUSTER  ports=${VSCODE_PORT}/${TTYD_PORT}  gw=${GW_IP})"

# WORKSPACE_MODE: mount (default) = bind-mount host repos RW; clone = ephemeral,
# repos cloned/reset each boot.
: "${WORKSPACE_MODE:=mount}"
case "$WORKSPACE_MODE" in
  mount|clone) ;;
  *) echo "WORKSPACE_MODE must be 'mount' or 'clone' (got '$WORKSPACE_MODE')"; exit 1 ;;
esac
echo "==> Workspace mode: $WORKSPACE_MODE"

# DOTFILES_MODE: default (ship minimal .zshrc) | chezmoi | host | none
: "${DOTFILES_MODE:=default}"
case "$DOTFILES_MODE" in
  default|chezmoi|host|none) ;;
  *) echo "DOTFILES_MODE must be default|chezmoi|host|none (got '$DOTFILES_MODE')"; exit 1 ;;
esac
echo "==> Dotfiles mode: $DOTFILES_MODE"

# --- preflight ---------------------------------------------------------------
missing=0
for t in docker k3d kubectl op envsubst base64; do
  command -v "$t" >/dev/null 2>&1 || { echo "MISSING prerequisite: $t"; missing=1; }
done
[[ "$missing" == 1 ]] && { echo "Install the missing tools (see README) and retry."; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker isn't running — start Docker Desktop and retry."; exit 1; }
op account get >/dev/null 2>&1 || { echo "Not signed in to 1Password CLI — run: eval \$(op signin)"; exit 1; }

OP_ACCOUNT_ARG=(); [[ -n "${OP_ACCOUNT:-}" ]] && OP_ACCOUNT_ARG=(--account "$OP_ACCOUNT")

# --- notes dir (OPTIONAL; host path mounted at /mnt/notes) -------------------
NOTES_MOUNT=""; NOTES_ENABLED=""
if [[ -n "${NOTES_DIR:-}" ]]; then
  mkdir -p "$NOTES_DIR"
  echo "==> Notes dir: $NOTES_DIR"
  NOTES_MOUNT=$'  - volume: '"$NOTES_DIR"$':/mnt/notes\n    nodeFilters: [server:0]'
  NOTES_ENABLED=1
else
  echo "==> Notes: disabled (NOTES_DIR unset)"
fi
export NOTES_MOUNT NOTES_ENABLED

# --- persistent state dir (Claude auth/memories/history + code-server + shell) -
mkdir -p "$STATE_DIR"
export STATE_DIR
echo "==> State dir (persists across down/up): $STATE_DIR"

# --- repos (mount mode only) → k3d volume(s) under /mnt/repos ----------------
REPOS_MOUNT=""
if [[ "$WORKSPACE_MODE" == mount ]]; then
  if [[ -n "${REPOS:-}" ]]; then
    echo "==> Mounting specific repos:"
    for r in $REPOS; do
      if [[ "$r" == /* ]]; then src="$r"; else
        : "${REPOS_DIR:?REPOS has relative names — set REPOS_DIR (base dir) in .env, or use absolute paths}"
        src="$REPOS_DIR/$r"
      fi
      [[ -d "$src" ]] || { echo "   repo not found: $src — fix REPOS/REPOS_DIR in .env."; exit 1; }
      name=$(basename "$src")
      echo "   + $name  ($src)"
      REPOS_MOUNT+=$'  - volume: '"$src"$':/mnt/repos/'"$name"$'\n    nodeFilters: [server:0]\n'
    done
  else
    : "${REPOS_DIR:?In mount mode set REPOS (list) or REPOS_DIR (whole dir) in .env}"
    [[ -d "$REPOS_DIR" ]] || { echo "REPOS_DIR '$REPOS_DIR' does not exist — create it or fix .env."; exit 1; }
    echo "==> Repos dir (whole, bind-mounted RW): $REPOS_DIR"
    REPOS_MOUNT=$'  - volume: '"$REPOS_DIR"$':/mnt/repos\n    nodeFilters: [server:0]'
  fi
fi
export REPOS_MOUNT

# --- dotfiles source (host/chezmoi modes only) → /mnt/dotfiles-src -----------
DOTFILES_MOUNT=""
if [[ "$DOTFILES_MODE" == host || "$DOTFILES_MODE" == chezmoi ]]; then
  if [[ "$DOTFILES_MODE" == chezmoi && -z "${DOTFILES_SRC:-}" ]]; then
    DOTFILES_SRC=$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")
    echo "==> DOTFILES_SRC auto-detected: $DOTFILES_SRC"
  fi
  : "${DOTFILES_SRC:?For DOTFILES_MODE=$DOTFILES_MODE set DOTFILES_SRC in .env (host dir with your dotfiles)}"
  [[ -d "$DOTFILES_SRC" ]] || { echo "DOTFILES_SRC '$DOTFILES_SRC' is not a directory — fix .env."; exit 1; }
  echo "==> Dotfiles source (RO): $DOTFILES_SRC"
  DOTFILES_MOUNT=$'  - volume: '"$DOTFILES_SRC"$':/mnt/dotfiles-src:ro\n    nodeFilters: [server:0]'
fi
export DOTFILES_MOUNT

# --- secrets from 1Password → gateway env (NEVER into the cluster) -----------
: "${OP_GH_PAT_REF:?Set OP_GH_PAT_REF in .env (op:// path to your scoped GitHub PAT)}"
echo "==> Reading scoped GitHub PAT from 1Password"
PAT="$(op read "${OP_ACCOUNT_ARG[@]}" "$OP_GH_PAT_REF")"
GH_AUTH_B64="$(printf 'x-access-token:%s' "$PAT" | base64 | tr -d '\n')"
# Anthropic auth is interactive OAuth (`claude /login`) inside the pod — no key
# is read or injected here. The model API just egresses through the allowlist.

# --- egress allowlist (defaults ∪ EGRESS_ALLOW), bind-mounted into the gateway -
# SECURITY: this MUST live outside $STATE_DIR. $STATE_DIR is bind-mounted RW into
# the agent pod (as /data), so anything under it is agent-writable — and this file
# is the gateway's egress policy *over* the agent. Under $STATE_DIR, a compromised
# agent could append its own exfil host and the gateway would live-reload it (≤10s),
# bypassing the one boundary it's not supposed to cross. The k3s node mounts only
# $STATE_DIR, so a sibling dir is invisible to the pod.
GW_STATE="$(dirname "$STATE_DIR")/gateway"; mkdir -p "$GW_STATE"
ALLOWLIST_FILE="$GW_STATE/allowlist"
# migrate away the old agent-writable copy if a prior up.sh created it under STATE_DIR
rm -f "$STATE_DIR/gateway/allowlist" 2>/dev/null || true
rmdir "$STATE_DIR/gateway" 2>/dev/null || true
{
  cat gateway/allowlist.default
  if [[ -n "${EGRESS_ALLOW:-}" ]]; then
    echo "# --- from EGRESS_ALLOW (.env) ---"
    printf '%s\n' $EGRESS_ALLOW
  fi
} > "$ALLOWLIST_FILE"
echo "==> Allowlist: $ALLOWLIST_FILE ($(grep -cvE '^\s*(#|$)' "$ALLOWLIST_FILE") domains)"

# --- docker networks ---------------------------------------------------------
# cs-*-internal: node + gateway live here. masquerade DISABLED → the node has no
# working direct egress; its only path out is the gateway (which doesn't forward).
# Still a normal bridge (not --internal) so k3d can publish the apiserver + the
# NodePort ports to the host.
if ! docker network inspect "$NET_INTERNAL" >/dev/null 2>&1; then
  docker network create \
    --subnet "$SUBNET" \
    -o com.docker.network.bridge.enable_ip_masquerade=false \
    "$NET_INTERNAL" >/dev/null
  echo "==> Created network $NET_INTERNAL ($SUBNET, no NAT)"
fi
# cs-*-egress: normal (masqueraded) bridge — the gateway's path to the internet.
docker network inspect "$NET_EGRESS" >/dev/null 2>&1 || \
  { docker network create "$NET_EGRESS" >/dev/null; echo "==> Created network $NET_EGRESS"; }

# --- gateway image + container ----------------------------------------------
echo "==> Building gateway image ($GW_IMAGE)"
docker build -q -t "$GW_IMAGE" gateway >/dev/null

gw_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$GW_NAME" 2>/dev/null)" == "true" ]]; }
# Host-relay ports are a start-time env (not live-reloadable like the allowlist), so
# recreate the gateway if the requested set differs from the running container's.
gw_relay_now() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$GW_NAME" 2>/dev/null | sed -n 's/^HOST_RELAY_PORTS=//p'; }
if [[ "$REBUILD_GATEWAY" == 1 ]] || ! gw_running || [[ "$(gw_relay_now)" != "${HOST_RELAY_PORTS:-}" ]]; then
  docker rm -f "$GW_NAME" >/dev/null 2>&1 || true
  # Start ON the internal net with the static IP (so dnsmasq can bind it at boot),
  # then attach the egress net for actual internet access.
  # host.docker.internal:host-gateway lets the gateway reach host services for the
  # opt-in HOST_RELAY_PORTS relays (auto on Docker Desktop, needed on plain Linux).
  docker run -d --name "$GW_NAME" --restart unless-stopped \
    --label "com.docker.compose.project=code-server-${NAME}" \
    --label com.docker.compose.service=gateway \
    --network "$NET_INTERNAL" --ip "$GW_IP" \
    --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=0 \
    --add-host host.docker.internal:host-gateway \
    -e GW_INTERNAL_IP="$GW_IP" \
    -e GH_AUTH_B64="$GH_AUTH_B64" \
    -e HOST_RELAY_PORTS="${HOST_RELAY_PORTS:-}" \
    -v "$ALLOWLIST_FILE":/etc/gateway/allowlist \
    "$GW_IMAGE" >/dev/null
  docker network connect "$NET_EGRESS" "$GW_NAME"
  echo "==> Gateway $GW_NAME up at $GW_IP (egress allowlist + DNS filter + git/anthropic proxy${HOST_RELAY_PORTS:+ + host relay $HOST_RELAY_PORTS})"
else
  echo "==> Gateway $GW_NAME already running — allowlist refreshed in place (live reload ≤10s)"
fi

# --- render k3d config + create cluster --------------------------------------
export VSCODE_PORT TTYD_PORT CLUSTER_NAME="$CLUSTER" NET_INTERNAL GW_IP API_PORT NO_PROXY_VAL NAME
K3D_CFG="k3d-cluster-${NAME}.yaml"
envsubst '${STATE_DIR} ${NOTES_MOUNT} ${REPOS_MOUNT} ${DOTFILES_MOUNT} ${VSCODE_PORT} ${TTYD_PORT} ${CLUSTER_NAME} ${NET_INTERNAL} ${GW_IP} ${API_PORT} ${NO_PROXY_VAL} ${NAME}' \
  < k3d-cluster.yaml.tmpl > "$K3D_CFG"
if k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CLUSTER"; then
  echo "==> k3d cluster '$CLUSTER' already exists"
  CLUSTER_EXISTED=1
else
  echo "==> Creating k3d cluster '$CLUSTER' on $NET_INTERNAL"
  k3d cluster create --config "$K3D_CFG"
  CLUSTER_EXISTED=0
fi
# Merge the cluster's kubeconfig into a SINGLE target file. k3d's own auto-merge
# (disabled in the config) bails when $KUBECONFIG lists several files; pick the
# first entry (else ~/.kube/config) and merge there so the context always lands.
KCFG_TARGET="${KUBECONFIG%%:*}"; KCFG_TARGET="${KCFG_TARGET:-$HOME/.kube/config}"
mkdir -p "$(dirname "$KCFG_TARGET")"
KUBECONFIG="$KCFG_TARGET" k3d kubeconfig merge "$CLUSTER" \
  --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null
kubectl config use-context "k3d-$CLUSTER" >/dev/null

# --- wire the node to route ALL egress through the gateway -------------------
# Default route + DNS → gateway. (Containerd image-pull proxy is NOT set here: it
# rides on HTTP(S)_PROXY env baked into the k3d node via k3d-cluster.yaml.tmpl,
# which k3s's embedded containerd inherits — no systemd drop-in like kind needed.
# That env also persists across `docker start`, unlike these runtime tweaks.)
# NOTE: these run-time route/DNS changes do NOT survive a host reboot / docker
# restart — re-run up.sh (idempotent) after a reboot to re-wire (see closing note).
echo "==> Wiring node egress through the gateway"
# busybox `ip` (in the k3s image) has no `route replace` → del + add.
docker exec "$NODE" sh -c "ip route del default 2>/dev/null; ip route add default via '$GW_IP'" 2>/dev/null \
  || echo "   ⚠ could not set node default route (validate manually)"
docker exec "$NODE" sh -c "printf 'nameserver %s\n' '$GW_IP' > /etc/resolv.conf" 2>/dev/null \
  || echo "   ⚠ could not set node resolv.conf"
# SECURITY: block pods reaching the host directly via the bridge gateway address
# (172.30.$OCTET.1 = the Docker bridge = the host). That .1 is a CONNECTED route, so
# masquerade=false + the default-route-via-gateway above do NOT cover it — a pod could
# otherwise hit any host port (e.g. host.k3d.internal, or the raw IP) on ALL 65535
# ports, bypassing the HOST_RELAY_PORTS allowlist that is meant to be the only host
# access. The sanctioned relay is pod->gateway($GW_IP)->host, which this rule does NOT
# touch. FORWARD only sees pod-forwarded traffic (src 10.42/16), so the node's own
# host access (OUTPUT) is unaffected. Runtime rule — re-run up.sh after a reboot.
HOST_BRIDGE_IP="172.30.${OCTET}.1"
docker exec "$NODE" sh -c \
  "iptables -C FORWARD -s 10.42.0.0/16 -d ${HOST_BRIDGE_IP} -j DROP 2>/dev/null \
   || iptables -I FORWARD 1 -s 10.42.0.0/16 -d ${HOST_BRIDGE_IP} -j DROP" 2>/dev/null \
  || echo "   ⚠ could not add host-bridge egress block (validate manually)"
# CoreDNS forwards external names to the node resolv.conf (= the gateway); restart
# so it picks up the change. Cluster (.svc) names stay internal.
kubectl -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true

# dotfiles mode → configmap the init container reads (envFrom, optional)
kubectl apply -f base/namespace.yaml >/dev/null
kubectl create configmap dotfiles-config -n code-server-work \
  --from-literal=DOTFILES_MODE="$DOTFILES_MODE" \
  --from-literal=NOTES_ENABLED="${NOTES_ENABLED:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- apply the chosen overlay ------------------------------------------------
# Image tag precedence: --tag > IMAGE_TAG env > most recent git tag.
# CI only rebuilds when image deps change (.github/workflows/build.yaml) and tags
# each built commit with the short SHA it pushed as the image tag. Defaulting to
# the latest git tag (not HEAD's SHA) means commits that DON'T trigger a rebuild
# (allowlist/.env/docs edits) keep resolving to the existing image — so committing
# them + re-running up.sh won't point the pod at a tag that was never built.
# (Run `git fetch --tags` to pick up tags from CI builds you don't have locally.)
IMAGE_TAG="${IMAGE_TAG_OVERRIDE:-${IMAGE_TAG:-}}"
if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG=$(git -C "$PWD" describe --tags --abbrev=0 2>/dev/null || true)
  [[ -z "$IMAGE_TAG" ]] && echo "   ⚠ no git tags found — falling back to :latest (let CI tag a build, or 'git fetch --tags')"
fi
[[ -z "$IMAGE_TAG" ]] && IMAGE_TAG="latest"
echo "==> Image: scottyjoe9/code-server:$IMAGE_TAG"
# Inject the per-instance gateway IP (GATEWAY_IP token) and image tag, then apply.
kubectl kustomize "overlays/$WORKSPACE_MODE" \
  | sed -E "s#(image: scottyjoe9/code-server):[^[:space:]\"]+#\1:${IMAGE_TAG}#g" \
  | sed -E "s#GATEWAY_IP#${GW_IP}#g" \
  | kubectl apply -f -

# clone mode: per-person repo list override (unchanged behaviour)
if [[ "$WORKSPACE_MODE" == clone && -n "${CLONE_REPOS:-}" ]]; then
  echo "==> Clone repos (from CLONE_REPOS):"
  printf '   + %s\n' $CLONE_REPOS
  kubectl create configmap work-repos -n code-server-work \
    --from-literal=repos="$(printf '%s\n' $CLONE_REPOS)" \
    --dry-run=client -o yaml | kubectl apply -f -
  [[ "${CLUSTER_EXISTED:-0}" == 1 ]] && \
    kubectl -n code-server-work rollout restart deploy/code-server >/dev/null 2>&1 || true
fi

echo "==> Waiting for rollout (first boot pulls the image$([[ "$WORKSPACE_MODE" == clone ]] && echo " + clones repos") via the gateway — be patient)…"
kubectl -n code-server-work rollout status deploy/code-server --timeout=600s || \
  echo "   (still settling — check: kubectl -n code-server-work get pods)"

cat <<EOF

✅ Sandbox '$NAME' up ($WORKSPACE_MODE mode). All traffic flows through gateway $GW_NAME ($GW_IP).
   VS Code  → http://localhost:${VSCODE_PORT}
   terminal → http://localhost:${TTYD_PORT}

Egress is allowlisted. Edit EGRESS_ALLOW in .env (or $ALLOWLIST_FILE) and re-run
./up.sh --name $NAME — the gateway live-reloads in ≤10s, no pod restart.
Egress audit log:  docker logs -f $GW_NAME

In Docker Desktop the gateway + k3d node are grouped under "code-server-${NAME}".

After a host reboot, re-run ./up.sh --name $NAME (idempotent): the node's default
route + DNS + host-bridge egress block are runtime settings that don't survive a
docker restart, so a bare 'docker start' brings the containers back but NOT their
egress wiring.

Tear down:  ./down.sh --name $NAME
EOF
