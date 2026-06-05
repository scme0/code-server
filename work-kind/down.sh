#!/usr/bin/env bash
# Tear down a work sandbox instance: the kind cluster, its gateway container,
# and its docker networks. Persistent state ($STATE_DIR) is KEPT by default
# (your Claude auth/memories survive) — pass --purge-state to delete it too.
set -euo pipefail
cd "$(dirname "$0")"

NAME="work"
PURGE_STATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         NAME="${2:?--name needs a value}"; shift 2;;
    --purge-state)  PURGE_STATE=1; shift;;
    -h|--help) echo "Usage: ./down.sh [--name NAME] [--purge-state]"; exit 0;;
    *) echo "Unknown arg: $1 (see --help)"; exit 1;;
  esac
done

[[ -f .env ]] && { set -a; . ./.env; set +a; }

CLUSTER="code-server-${NAME}"
GW_NAME="cs-${NAME}-gateway"
NET_INTERNAL="cs-${NAME}-internal"
NET_EGRESS="cs-${NAME}-egress"
if [[ "$NAME" == "work" && -n "${STATE_DIR:-}" ]]; then :; else
  STATE_DIR="$HOME/.code-server-${NAME}/state"
fi

kind delete cluster --name "$CLUSTER" 2>/dev/null || true
docker rm -f "$GW_NAME" >/dev/null 2>&1 || true
docker network rm "$NET_INTERNAL" "$NET_EGRESS" >/dev/null 2>&1 || true
rm -f "kind-cluster-${NAME}.yaml"
echo "✅ Torn down instance '$NAME' (cluster + gateway + networks)."

if [[ "$PURGE_STATE" == 1 ]]; then
  rm -rf "$STATE_DIR"
  echo "🗑  Purged state dir: $STATE_DIR"
else
  echo "   State kept at: $STATE_DIR  (use --purge-state to delete)"
fi
