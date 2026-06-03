#!/usr/bin/env bash
# Create the per-person secrets in the cluster from 1Password. Never commits
# anything. Re-runnable (apply-style). Requires `op` signed in to the work account.
set -euo pipefail
NS=code-server-work

[[ -f "$(dirname "$0")/.env" ]] && { set -a; . "$(dirname "$0")/.env"; set +a; }

: "${OP_GH_PAT_REF:?Set OP_GH_PAT_REF in .env (op:// path to your scoped GitHub PAT)}"

echo "==> Reading scoped GitHub PAT from 1Password"
PAT="$(op read "$OP_GH_PAT_REF")"
# GitHub git-over-HTTPS basic auth: base64("x-access-token:<PAT>")
GH_AUTH_B64="$(printf 'x-access-token:%s' "$PAT" | base64 | tr -d '\n')"

kubectl create secret generic git-proxy-auth -n "$NS" \
  --from-literal=gh-auth-b64="$GH_AUTH_B64" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "    git-proxy-auth ✓"

if [[ -n "${OP_ANTHROPIC_REF:-}" ]]; then
  echo "==> Reading Anthropic API key from 1Password"
  KEY="$(op read "$OP_ANTHROPIC_REF")"
  kubectl create secret generic anthropic-api-key -n "$NS" \
    --from-literal=api-key="$KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    anthropic-api-key ✓"
else
  echo "==> OP_ANTHROPIC_REF unset — skipping API key (use \`claude /login\` in the pod)"
fi
