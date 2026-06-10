#!/usr/bin/env bash
# Smoke-test a running local-secure sandbox instance: k3d cluster + node wiring +
# Docker-UI grouping + the egress boundary (the security-critical part). Read-only;
# changes nothing. Run AFTER ./up.sh. Pass --name NAME to test a non-default instance.
#
#   ./smoke-test.sh                # the default "work" instance
#   ./smoke-test.sh --name test    # a named instance
#
# Exit 0 = all passed; non-zero = at least one FAIL (count printed at the end).
set -uo pipefail
cd "$(dirname "$0")"

# --- args + per-instance identifiers (mirrors up.sh) -------------------------
NAME="work"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:?--name needs a value}"; shift 2;;
    -h|--help) echo "Usage: ./smoke-test.sh [--name NAME]"; exit 0;;
    *) echo "Unknown arg: $1 (see --help)"; exit 1;;
  esac
done
[[ -f .env ]] && { set -a; . ./.env; set +a; }

CLUSTER="code-server-${NAME}"
NODE="k3d-${CLUSTER}-server-0"
SERVERLB="k3d-${CLUSTER}-serverlb"
GW_NAME="cs-${NAME}-gateway"
NET_INTERNAL="cs-${NAME}-internal"
CTX="k3d-${CLUSTER}"
NS="code-server-work"
PROJECT_LABEL="code-server-${NAME}"
if [[ "$NAME" == "work" ]]; then
  OCTET=0; VSCODE_PORT="${VSCODE_PORT:-4444}"; TTYD_PORT="${TTYD_PORT:-7681}"
else
  OCTET=$(( $(printf '%s' "$NAME" | cksum | cut -d' ' -f1) % 250 + 1 ))
  VSCODE_PORT="${VSCODE_PORT:-$((4444 + OCTET))}"
  TTYD_PORT="${TTYD_PORT:-$((7681 + OCTET))}"
fi
GW_IP="172.30.${OCTET}.2"

K="kubectl --context $CTX"

# --- pretty check helpers ----------------------------------------------------
PASS=0; FAIL=0; SKIP=0
green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
yellow(){ printf '\033[33m%s\033[0m' "$1"; }
ok()   { PASS=$((PASS+1)); printf '  [%s] %s\n' "$(green PASS)" "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  [%s] %s\n' "$(red FAIL)" "$1"; [[ -n "${2:-}" ]] && printf '         ↳ %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  [%s] %s\n' "$(yellow SKIP)" "$1"; [[ -n "${2:-}" ]] && printf '         ↳ %s\n' "$2"; }
section() { printf '\n=== %s ===\n' "$1"; }

# pass if `cmd` succeeds; fail otherwise. usage: expect "desc" cmd args...
expect()      { local d="$1"; shift; if out=$("$@" 2>&1); then ok "$d"; else no "$d" "$out"; fi; }
# pass if `cmd` FAILS (for fail-closed / blocked checks)
expect_fail() { local d="$1"; shift; if out=$("$@" 2>&1); then no "$d" "expected failure, but it succeeded: $out"; else ok "$d"; fi; }
# pass if stdout of cmd contains the needle
expect_grep() { local d="$1" needle="$2"; shift 2; if "$@" 2>/dev/null | grep -q -- "$needle"; then ok "$d"; else no "$d" "expected to find '$needle'"; fi; }

echo "Smoke-testing instance '$NAME'  (cluster=$CLUSTER  gw=$GW_IP  ports=${VSCODE_PORT}/${TTYD_PORT})"

# --- 1. prerequisites + cluster existence -----------------------------------
section "Tooling & cluster"
for t in docker k3d kubectl; do
  command -v "$t" >/dev/null 2>&1 && ok "$t on PATH" || no "$t on PATH" "install it"
done
expect_grep "k3d cluster '$CLUSTER' exists" "$CLUSTER" sh -c "k3d cluster list -o json 2>/dev/null | tr ',' '\n' | grep name"
expect "kube context '$CTX' resolves + node Ready" \
  sh -c "$K get nodes 2>/dev/null | grep -qw Ready"

# --- 2. containers running ---------------------------------------------------
section "Containers"
running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
for c in "$GW_NAME" "$NODE" "$SERVERLB"; do
  if running "$c"; then ok "container running: $c"; else no "container running: $c" "not running"; fi
done

# --- 3. Docker-Desktop grouping (the feature this migration added) ----------
section "Docker UI grouping (com.docker.compose.project=$PROJECT_LABEL)"
label_of() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null; }
for c in "$GW_NAME" "$NODE" "$SERVERLB"; do
  l="$(label_of "$c")"
  if [[ "$l" == "$PROJECT_LABEL" ]]; then ok "$c labelled '$PROJECT_LABEL'"
  else no "$c grouping label" "got '$l', want '$PROJECT_LABEL'"; fi
done

# --- 4. node egress wiring (default route + DNS + containerd proxy) ----------
section "Node egress wiring"
expect_grep "node default route → gateway ($GW_IP)" "default via $GW_IP" \
  docker exec "$NODE" ip route
expect_grep "node resolv.conf → gateway ($GW_IP)" "$GW_IP" \
  docker exec "$NODE" cat /etc/resolv.conf
expect_grep "node HTTP_PROXY env → gateway (containerd image pulls)" "http://$GW_IP:8888" \
  docker exec "$NODE" printenv HTTP_PROXY

# --- 5. workload rolled out + host ports reachable --------------------------
section "Workload & host ports"
expect "code-server deployment Available" \
  sh -c "$K -n $NS rollout status deploy/code-server --timeout=10s"
expect "VS Code port reachable (127.0.0.1:$VSCODE_PORT)" \
  sh -c "curl -fsS -m 8 -o /dev/null http://127.0.0.1:${VSCODE_PORT}/healthz || curl -fsS -m 8 -o /dev/null http://127.0.0.1:${VSCODE_PORT}/"
expect "terminal port reachable (127.0.0.1:$TTYD_PORT)" \
  sh -c "curl -fsS -m 8 -o /dev/null http://127.0.0.1:${TTYD_PORT}/"

# --- 6. THE EGRESS BOUNDARY (security-critical) -----------------------------
# From inside the agent pod. The pod has HTTP(S)_PROXY → gateway:8888; the gateway
# allowlists domains and the node can't IP-forward, so anything ignoring the proxy
# is fail-closed. We assert: allowlisted works, non-allowlisted blocked, bypass dead.
section "Egress boundary (from the agent pod)"
POD="$($K -n $NS get pod -l app.kubernetes.io/name=code-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -z "$POD" ]]; then
  skip "egress tests" "no code-server pod found"
else
  ex() { $K -n "$NS" exec "$POD" -c code-server -- sh -c "$1" 2>/dev/null; }
  if ex 'command -v curl >/dev/null'; then
    # allowlisted (github.com is in allowlist.default) — via the proxy → should connect
    expect "allowlisted egress works (github.com via proxy)" \
      sh -c "$K -n $NS exec $POD -c code-server -- curl -fsS -m 20 -o /dev/null https://github.com"
    # non-allowlisted — proxy must refuse (curl returns non-zero / 403)
    expect_fail "non-allowlisted egress BLOCKED (example.com via proxy)" \
      sh -c "$K -n $NS exec $POD -c code-server -- curl -fsS -m 15 -o /dev/null https://example.com"
    # bypass the proxy entirely — node won't forward → must fail (fail-closed)
    expect_fail "direct egress BLOCKED (bypass proxy → fail-closed)" \
      sh -c "$K -n $NS exec $POD -c code-server -- curl -fsS -m 12 --noproxy '*' -o /dev/null https://github.com"
  else
    skip "egress tests" "curl not found in the pod"
  fi
fi

# --- summary -----------------------------------------------------------------
section "Summary"
printf '  %s passed, %s failed, %s skipped\n' "$(green $PASS)" "$([[ $FAIL -gt 0 ]] && red $FAIL || echo $FAIL)" "$(yellow $SKIP)"
if [[ $FAIL -gt 0 ]]; then
  printf '\n%s — boundary or wiring issue above. Do NOT trust this instance until green.\n' "$(red 'SMOKE TEST FAILED')"
  exit 1
fi
printf '\n%s for instance "%s".\n' "$(green 'ALL GOOD')" "$NAME"
