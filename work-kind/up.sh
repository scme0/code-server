#!/usr/bin/env bash
# Spin up the work sandbox on a local kind cluster. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
CLUSTER=code-server-work

# --- args --------------------------------------------------------------------
IMAGE_TAG_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag|--image-tag) IMAGE_TAG_OVERRIDE="${2:?--tag needs a value}"; shift 2;;
    --latest)          IMAGE_TAG_OVERRIDE="latest"; shift;;
    -h|--help) echo "Usage: ./up.sh [--tag <image-tag> | --latest]   (default: current git short SHA)"; exit 0;;
    *) echo "Unknown arg: $1 (see --help)"; exit 1;;
  esac
done

# --- load per-person config -------------------------------------------------
[[ -f .env ]] && { set -a; . ./.env; set +a; }

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
for t in docker kind kubectl op envsubst base64; do
  command -v "$t" >/dev/null 2>&1 || { echo "MISSING prerequisite: $t"; missing=1; }
done
[[ "$missing" == 1 ]] && { echo "Install the missing tools (see README) and retry."; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker isn't running — start Docker Desktop and retry."; exit 1; }
op account get >/dev/null 2>&1 || { echo "Not signed in to 1Password CLI — run: eval \$(op signin)"; exit 1; }

# --- notes dir (OPTIONAL; host path mounted at /mnt/notes) -------------------
# Unset → notes fully ignored: no mount, no workspace folder, no symlink.
NOTES_MOUNT=""; NOTES_ENABLED=""
if [[ -n "${NOTES_DIR:-}" ]]; then
  mkdir -p "$NOTES_DIR"
  echo "==> Notes dir: $NOTES_DIR"
  NOTES_MOUNT=$'      - hostPath: '"$NOTES_DIR"$'\n        containerPath: /mnt/notes'
  NOTES_ENABLED=1
else
  echo "==> Notes: disabled (NOTES_DIR unset)"
fi
export NOTES_MOUNT NOTES_ENABLED

# --- persistent state dir (Claude auth/memories/history + code-server + shell) -
# Host-mounted at /data so it survives down.sh/recreate. Dedicated dir, separate
# from your real ~/.claude.
: "${STATE_DIR:=$HOME/.code-server-work/state}"
mkdir -p "$STATE_DIR"
export STATE_DIR
echo "==> State dir (persists across down/up): $STATE_DIR"

# --- repos (mount mode only) → kind extraMount(s) under /mnt/repos -----------
# REPOS (a list) wins: mount each listed repo individually → /data/workspace holds
# ONLY those (fast). Otherwise fall back to the whole REPOS_DIR.
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
      REPOS_MOUNT+=$'      - hostPath: '"$src"$'\n        containerPath: /mnt/repos/'"$name"$'\n'
    done
  else
    : "${REPOS_DIR:?In mount mode set REPOS (list) or REPOS_DIR (whole dir) in .env}"
    [[ -d "$REPOS_DIR" ]] || { echo "REPOS_DIR '$REPOS_DIR' does not exist — create it or fix .env."; exit 1; }
    echo "==> Repos dir (whole, bind-mounted RW): $REPOS_DIR"
    REPOS_MOUNT=$'      - hostPath: '"$REPOS_DIR"$'\n        containerPath: /mnt/repos'
  fi
fi
export REPOS_MOUNT

# --- dotfiles source (host/chezmoi modes only) → /mnt/dotfiles-src -----------
DOTFILES_MOUNT=""
if [[ "$DOTFILES_MODE" == host || "$DOTFILES_MODE" == chezmoi ]]; then
  # chezmoi: auto-resolve the local source dir if DOTFILES_SRC isn't set, so you
  # only need DOTFILES_MODE=chezmoi. Falls back to the conventional path.
  if [[ "$DOTFILES_MODE" == chezmoi && -z "${DOTFILES_SRC:-}" ]]; then
    DOTFILES_SRC=$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")
    echo "==> DOTFILES_SRC auto-detected: $DOTFILES_SRC"
  fi
  : "${DOTFILES_SRC:?For DOTFILES_MODE=$DOTFILES_MODE set DOTFILES_SRC in .env (host dir with your dotfiles)}"
  [[ -d "$DOTFILES_SRC" ]] || { echo "DOTFILES_SRC '$DOTFILES_SRC' is not a directory — fix .env (chezmoi: install/init it, or set DOTFILES_SRC)."; exit 1; }
  echo "==> Dotfiles source (RO): $DOTFILES_SRC"
  DOTFILES_MOUNT=$'      - hostPath: '"$DOTFILES_SRC"$'\n        containerPath: /mnt/dotfiles-src\n        readOnly: true'
fi
export DOTFILES_MOUNT

# --- render kind config + create cluster -------------------------------------
envsubst '${STATE_DIR} ${NOTES_MOUNT} ${REPOS_MOUNT} ${DOTFILES_MOUNT}' < kind-cluster.yaml.tmpl > kind-cluster.yaml
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "==> kind cluster '$CLUSTER' already exists"
  CLUSTER_EXISTED=1
else
  echo "==> Creating kind cluster '$CLUSTER'"
  kind create cluster --config kind-cluster.yaml
  CLUSTER_EXISTED=0
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# --- namespace + secrets (secrets need the ns to exist) ----------------------
kubectl apply -f base/namespace.yaml
./setup-secrets.sh

# dotfiles mode → configmap the init container reads (envFrom, optional)
kubectl create configmap dotfiles-config -n "$CLUSTER" \
  --from-literal=DOTFILES_MODE="$DOTFILES_MODE" \
  --from-literal=NOTES_ENABLED="${NOTES_ENABLED:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- everything else (the chosen overlay) ------------------------------------
# Image tag precedence: --tag arg > IMAGE_TAG env > current git commit SHA. CI
# tags images by short SHA, so the git default matches the image built for this
# checkout (no manual bump, no drift). Use --tag to point at any already-built
# tag — e.g. while HEAD is still building, or to pin an older known-good image.
IMAGE_TAG="${IMAGE_TAG_OVERRIDE:-${IMAGE_TAG:-}}"
if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG=$(git -C "$PWD" rev-parse --short HEAD 2>/dev/null || true)
  if [[ -n "$IMAGE_TAG" ]] && ! git -C "$PWD" diff --quiet HEAD 2>/dev/null; then
    echo "   ⚠ uncommitted changes — image:$IMAGE_TAG won't include them (commit + push, or pass --tag)"
  fi
fi
if [[ -n "$IMAGE_TAG" ]]; then
  echo "==> Image: scottyjoe9/code-server:$IMAGE_TAG"
  kubectl kustomize "overlays/$WORKSPACE_MODE" \
    | sed -E "s#(image: scottyjoe9/code-server):[^[:space:]\"]+#\1:${IMAGE_TAG}#g" \
    | kubectl apply -f -
else
  echo "==> No tag (not a git checkout, no --tag/IMAGE_TAG) — using base/kustomization pin"
  kubectl apply -k "overlays/$WORKSPACE_MODE"
fi

# clone mode: override the `work-repos` configmap from CLONE_REPOS (.env) so the
# repo list is per-person without editing base/configmaps.yaml. Applied AFTER the
# overlay so it wins over the committed placeholder default. CLONE_REPOS is a
# space/newline list of owner/repo slugs; empty → keep the committed default.
if [[ "$WORKSPACE_MODE" == clone && -n "${CLONE_REPOS:-}" ]]; then
  echo "==> Clone repos (from CLONE_REPOS):"
  printf '   + %s\n' $CLONE_REPOS
  kubectl create configmap work-repos -n "$CLUSTER" \
    --from-literal=repos="$(printf '%s\n' $CLONE_REPOS)" \
    --dry-run=client -o yaml | kubectl apply -f -
  # On a fresh cluster the init container hasn't read the configmap yet (image is
  # still pulling), so it picks up this list with no restart. On an existing
  # cluster the running pod already ran reset-repos — restart so it re-runs with
  # the new list.
  [[ "${CLUSTER_EXISTED:-0}" == 1 ]] && \
    kubectl -n "$CLUSTER" rollout restart deploy/code-server >/dev/null 2>&1 || true
fi

echo "==> Waiting for rollout (first boot pulls the image$([[ "$WORKSPACE_MODE" == clone ]] && echo " + clones repos") — be patient)…"
kubectl -n "$CLUSTER" rollout status deploy/code-server --timeout=600s || \
  echo "   (still settling — check: kubectl -n $CLUSTER get pods)"

cat <<EOF

✅ Work sandbox up ($WORKSPACE_MODE mode). Access directly (no port-forward — ports published by kind):
   VS Code  → http://localhost:4444
   terminal → http://localhost:7681

After a reboot, just restart the node container (no need to re-run up.sh):
   docker start ${CLUSTER}-control-plane

Tear down:  ./down.sh
EOF
