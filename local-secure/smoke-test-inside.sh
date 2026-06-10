#!/usr/bin/env bash
# Config-verification diagnostic — run BY HAND from inside the code-server sandbox
# terminal (not the host). Confirms the boundary + plumbing behave as designed:
# gateway allow/deny, DNS sinkhole, git-proxy credential injection, no creds in the
# pod, mounts, and RBAC scoping.
#
#   ./local-secure/smoke-test-inside.sh      # from /data/workspace/code-server
#
# NOT a security gate. It runs INSIDE the (potentially untrusted) sandbox, so a
# compromised pod could fake green — the authoritative boundary verdict is the
# host-side ./smoke-test.sh. This just answers "did Claude wire it up right?".
set -uo pipefail

PASS=0; FAIL=0; SKIP=0; INFO=0
green(){ printf '\033[32m%s\033[0m' "$1"; }; red(){ printf '\033[31m%s\033[0m' "$1"; }; yellow(){ printf '\033[33m%s\033[0m' "$1"; }
ok()   { PASS=$((PASS+1)); printf '  [%s] %s\n' "$(green PASS)" "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  [%s] %s\n' "$(red FAIL)" "$1"; [[ -n "${2:-}" ]] && printf '         ↳ %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  [%s] %s\n' "$(yellow SKIP)" "$1"; [[ -n "${2:-}" ]] && printf '         ↳ %s\n' "$2"; }
info() { INFO=$((INFO+1)); printf '  [%s] %s\n' "info" "$1"; [[ -n "${2:-}" ]] && printf '         ↳ %s\n' "$2"; }
section(){ printf '\n=== %s ===\n' "$1"; }

have(){ command -v "$1" >/dev/null 2>&1; }

# sanity: are we actually inside the sandbox?
if [[ ! -d /data/home && -z "${CODE_SERVER_SANDBOX:-}" ]]; then
  echo "This looks like the HOST, not the sandbox. Run it from the code-server terminal."
  echo "(no /data/home and CODE_SERVER_SANDBOX unset)"; exit 2
fi

# gateway IP from the proxy env (set in the deployment)
GW_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
GW_HOST="$(printf '%s' "$GW_PROXY" | sed -E 's#https?://([^:/]+).*#\1#')"
echo "Inside-sandbox diagnostic.  proxy=$GW_PROXY  gateway=$GW_HOST"

# --- 1. environment: proxy set, NO creds in the pod -------------------------
section "Environment & credentials"
[[ -n "$GW_PROXY" ]] && ok "HTTP(S)_PROXY points at the gateway" || no "HTTP(S)_PROXY set" "empty — pod has no egress path"
case "${NO_PROXY:-}" in
  *10.0.0.0/8*|*cluster.local*) ok "NO_PROXY excludes cluster/internal ranges" ;;
  *) no "NO_PROXY excludes cluster ranges" "got '${NO_PROXY:-}'" ;;
esac
# the WHOLE POINT: no GitHub token lives here (it's in the gateway)
creds_found=""
for v in GITHUB_TOKEN GH_TOKEN GITHUB_PAT GH_PAT; do [[ -n "${!v:-}" ]] && creds_found="$creds_found $v"; done
[[ -f "$HOME/.git-credentials" ]] && creds_found="$creds_found ~/.git-credentials"
[[ -z "$creds_found" ]] && ok "no GitHub credential present in the pod (lives in gateway)" \
  || no "no GitHub credential in the pod" "found:$creds_found — token leaked into the sandbox"

# --- 2. git is rewritten to the gateway git-proxy (no token here) -----------
section "Git proxy (credential injection at the gateway)"
if have git; then
  rewrite="$(git config --get-regexp 'url\..*\.insteadof' 2>/dev/null || true)"
  printf '%s' "$rewrite" | grep -q ':8088/' \
    && ok "git rewrites github.com → gateway git-proxy (:8088)" \
    || no "git insteadOf rewrite to :8088" "got: ${rewrite:-<none>}  (check GIT_CONFIG_GLOBAL=$GIT_CONFIG_GLOBAL)"
  # functional: ls-remote a public repo — succeeds via the gateway with NO token here
  if git ls-remote https://github.com/kubernetes-sigs/kind.git HEAD >/dev/null 2>&1; then
    ok "git ls-remote over the gateway works (tokenless from pod)"
  else
    no "git ls-remote over the gateway" "if the gateway PAT can't read public repos, this may be expected — check 'docker logs cs-<name>-gateway' on the host"
  fi
else skip "git checks" "git not found"; fi

# --- 3. gateway egress rules: allow / deny / fail-closed --------------------
section "Gateway egress rules"
if have curl; then
  # curl's -w always prints the code (000 if it never connected); no `|| echo`
  # fallback — that doubled the output to "000000" on a blocked request.
  code(){ curl -s -m "$2" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }
  # allowlisted (github.com is in allowlist.default) via proxy → reaches origin
  c=$(code https://github.com 20)
  [[ "$c" =~ ^(2|3) ]] && ok "allowlisted github.com via proxy → $c (allowed)" \
    || no "allowlisted github.com via proxy" "got $c (000=no connect, 403=proxy denied)"
  # anthropic reachable (OAuth path) — origin will 401/200, NOT a proxy 000
  c=$(code https://api.anthropic.com 20)
  [[ "$c" != "000" ]] && ok "api.anthropic.com reachable via proxy → $c (allowed; 401 = origin reached)" \
    || no "api.anthropic.com reachable" "got 000 — couldn't connect (allowlist/DNS?)"
  # non-allowlisted → proxy must deny
  c=$(code https://example.com 15)
  { [[ "$c" == "403" || "$c" == "000" ]]; } && ok "non-allowlisted example.com BLOCKED → $c" \
    || no "non-allowlisted example.com blocked" "got $c — it was reachable; allowlist too wide"
  # bypass the proxy entirely → node can't forward → must fail (fail-closed)
  if curl -fsS -m 12 --noproxy '*' -o /dev/null https://github.com 2>/dev/null; then
    no "direct egress fail-closed (proxy bypass)" "direct connection SUCCEEDED — node has a non-gateway egress path!"
  else ok "direct egress fail-closed (proxy bypass → dead)"; fi
else skip "egress rule checks" "curl not found"; fi

# host-bridge bypass: the docker bridge .1 (same /24 as the gateway, here the .2)
# IS the host on a CONNECTED route, so the gateway/route wiring doesn't cover it.
# Without the node FORWARD drop a pod reaches the host on ALL ports, bypassing the
# HOST_RELAY_PORTS allowlist. Reachable (RST or connect) = FAIL; timeout = blocked.
if have python3 && [[ "$GW_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  HOST_BRIDGE_IP="${GW_HOST%.*}.1"
  if python3 - "$HOST_BRIDGE_IP" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(); s.settimeout(4)
try:
    s.connect((sys.argv[1], 19999)); sys.exit(1)   # connected → reachable
except ConnectionRefusedError:
    sys.exit(1)                                     # RST → host reachable, no listener
except Exception:
    sys.exit(0)                                     # timeout/unreachable → blocked
finally:
    s.close()
PY
  then ok "host-bridge bypass blocked (can't reach host $HOST_BRIDGE_IP on a non-relay port)"
  else no "host-bridge bypass blocked" "reached host $HOST_BRIDGE_IP directly — node FORWARD drop missing (re-run up.sh on the host)"; fi
else skip "host-bridge bypass check" "python3 missing or gateway IP not numeric"; fi

# --- 4. DNS filtering (dnsmasq sinkhole on the gateway) ---------------------
section "DNS filter"
if have getent; then
  if getent hosts github.com >/dev/null 2>&1; then ok "allowlisted name resolves (github.com)"; else no "github.com resolves"; fi
  sink="$(getent hosts no-such-evil-domain.example 2>/dev/null | awk '{print $1}')"
  { [[ -z "$sink" || "$sink" == "0.0.0.0" ]]; } && ok "non-allowlisted name sinkholed/NXDOMAIN" \
    || no "non-allowlisted name sinkholed" "resolved to $sink — DNS filter not catching it"
else skip "DNS checks" "getent not found"; fi

# --- 5. mounts present ------------------------------------------------------
section "Mounts & persistence"
[[ -d /data/home ]] && ok "persisted state /data/home present" || no "/data/home present"
[[ -d /data/workspace ]] && ok "workspace /data/workspace present" || no "/data/workspace present"
if [[ -n "$(ls -A /data/workspace 2>/dev/null)" ]]; then ok "workspace has repo(s)"; else info "workspace empty" "expected if no REPOS mounted / clone not finished"; fi
if [[ -e /mnt/notes ]]; then ok "/mnt/notes mounted"; else info "/mnt/notes absent" "expected if NOTES_DIR unset"; fi
[[ -f "$HOME/.zshrc" ]] && ok "shell dotfiles present (~/.zshrc)" || info "~/.zshrc absent" "expected for DOTFILES_MODE=none"

# --- 6. k8s access is scoped (RBAC) -----------------------------------------
section "Kubernetes RBAC scope (k8s-run)"
if have kubectl; then
  kubectl auth can-i create pods -n code-server-work >/dev/null 2>&1 \
    && ok "can create pods in own namespace (k8s-run works)" || no "can create pods in code-server-work"
  if kubectl auth can-i create pods -n kube-system >/dev/null 2>&1; then
    no "RBAC is scoped" "can create pods in kube-system — SA is over-privileged!"
  else ok "cannot create pods in kube-system (scope enforced)"; fi
  if kubectl auth can-i get secrets -n code-server-work >/dev/null 2>&1; then
    no "cannot read secrets" "SA can read secrets — tighten the Role"
  else ok "cannot read secrets (no secret-steal)"; fi
else skip "RBAC checks" "kubectl not found in pod"; fi

# --- summary ----------------------------------------------------------------
section "Summary"
printf '  %s passed, %s failed, %s skipped, %s info\n' "$(green $PASS)" "$([[ $FAIL -gt 0 ]] && red $FAIL || echo 0)" "$(yellow $SKIP)" "$INFO"
printf '  (diagnostic only — boundary authority is the host-side ./smoke-test.sh)\n'
[[ $FAIL -gt 0 ]] && { printf '\n%s — config differs from design; see FAILs above.\n' "$(red 'ISSUES FOUND')"; exit 1; }
printf '\n%s — config behaves as designed.\n' "$(green 'ALL GOOD')"
