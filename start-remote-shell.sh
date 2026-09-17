#!/bin/bash
# Native-terminal access to the same tmux session ttyd serves: sshd on 2222 and
# Eternal Terminal (etserver) on 2022, both running as the pod user.
#
# Started in the background by start-ttyd.sh when REMOTE_SHELL=1, so it shares
# ttyd's container and therefore its /tmp, which is where the tmux socket lives.
# An ssh or et client that runs `tmux new-session -A -s main` attaches to the
# same server ttyd does.
#
# Non-root sshd can only log in the user it runs as, which is the point: the
# only account reachable is the pod user, by public key, nothing else.
#
# Inputs:
#   REMOTE_SHELL_KEYS  file of authorized public keys (mounted from a ConfigMap).
#                      Copied over ~/.ssh/authorized_keys on every start, so
#                      the deploy config is the only source of truth.
#   REMOTE_SHELL_STATE persistent dir for the host key (default /data/sshd), so
#                      the fingerprint survives pod restarts.

set -u

KEYS_SRC="${REMOTE_SHELL_KEYS:-/etc/remote-shell/authorized_keys}"
STATE="${REMOTE_SHELL_STATE:-/data/sshd}"
RUN=/tmp/remote-shell
# etserver and the etterminal that each ssh login spawns must agree on this dir:
# the router socket lives at $XDG_RUNTIME_DIR/etserver/. Kept off the PVC
# because /data is NFS, and unix sockets don't belong there.
RUNTIME_DIR=/tmp/runtime-$(id -u)

log() { echo "remote-shell: $*"; }

mkdir -p "$STATE" "$RUN" "$RUNTIME_DIR" "$HOME/.ssh"
chmod 700 "$STATE" "$RUN" "$RUNTIME_DIR" "$HOME/.ssh"

if [ ! -f "$STATE/ssh_host_ed25519_key" ]; then
  log "generating host key"
  ssh-keygen -q -t ed25519 -N '' -f "$STATE/ssh_host_ed25519_key"
fi
chmod 600 "$STATE/ssh_host_ed25519_key"
log "host key $(ssh-keygen -lf "$STATE/ssh_host_ed25519_key.pub")"

# Keys live under $HOME because sshd's StrictModes walks every parent of the
# keys file and rejects a group/world-writable one. It stops at the home dir,
# and /data itself is 0777.
if [ -f "$KEYS_SRC" ]; then
  install -m 600 "$KEYS_SRC" "$HOME/.ssh/authorized_keys"
else
  : > "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
fi
log "$(grep -c '^[^#[:space:]]' "$HOME/.ssh/authorized_keys" || true) authorized key(s)"

# sshd hands sessions a bare environment, so carry over what the container env
# sets. New tmux windows take the tmux server's env anyway; this is for plain
# ssh commands, and for etterminal, which needs XDG_RUNTIME_DIR.
# sshd keeps only the first SetEnv line, so every pair goes on one.
setenv="SetEnv \"XDG_RUNTIME_DIR=$RUNTIME_DIR\""
for var in PATH LANG LC_ALL CLAUDE_CONFIG_DIR CLAUDE_CLI_PATH GITSTATUS_CACHE_DIR TALOSCONFIG; do
  val="${!var-}"
  [ -n "$val" ] && setenv+=" \"$var=$val\""
done
echo "$setenv" > "$RUN/sshd_env.conf"

cat > "$RUN/sshd_config" <<EOF
Port 2222
HostKey $STATE/ssh_host_ed25519_key
PidFile $RUN/sshd.pid
UsePAM no

AllowUsers $(id -un)
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no

AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
PrintMotd no

ClientAliveInterval 30
ClientAliveCountMax 4

Include $RUN/sshd_env.conf
EOF

cat > "$RUN/et.cfg" <<EOF
[Networking]
port = 2022

[Debug]
verbose = 0
silent = 0
telemetry = false
logdirectory = $RUN
EOF

# Keep both alive for the life of the container. Neither is worth taking ttyd
# down over, so they restart themselves instead of failing the pod.
supervise() {
  local name=$1; shift
  while :; do
    "$@"
    log "$name exited ($?), restarting in 5s"
    sleep 5
  done
}

supervise sshd /usr/sbin/sshd -D -e -f "$RUN/sshd_config" &
(export XDG_RUNTIME_DIR="$RUNTIME_DIR"; supervise etserver etserver --cfgfile "$RUN/et.cfg") &
wait
