#!/bin/bash
# Starts ttyd with the mobile controller script injected into its frontend.
# Spins up a temp instance to grab the built-in index.html, injects the
# script inline, then launches the real ttyd against the patched file.

set -e

SCRIPT_PATH="/usr/local/lib/mobile-controller.js"
CUSTOM_HTML="/tmp/ttyd-custom.html"

# Grab built-in index.html via a short-lived ttyd on a temp port
ttyd --port 7699 bash &
TEMP_PID=$!
sleep 1
curl -sf http://127.0.0.1:7699 -o /tmp/ttyd-raw.html
kill "$TEMP_PID" 2>/dev/null || true
wait "$TEMP_PID" 2>/dev/null || true

# Inject mobile controller before </body>
node -e "
const fs = require('fs');
const html = fs.readFileSync('/tmp/ttyd-raw.html', 'utf8');
const script = fs.readFileSync('$SCRIPT_PATH', 'utf8');
const patched = html.replace('</body>', '<script>' + script + '</script></body>');
fs.writeFileSync('$CUSTOM_HTML', patched);
console.log('Patched ttyd index.html with mobile controller');
"

# Launch real ttyd — tmux for session persistence, zsh -l for dotfiles
exec ttyd \
  --writable \
  --port 7681 \
  --cwd /data/workspace \
  -t fontSize=12 \
  -t copyOnSelect=true \
  --index "$CUSTOM_HTML" \
  tmux new-session -A -s main zsh -l
