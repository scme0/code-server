#!/usr/bin/env bash
# Tear down the work sandbox (deletes the kind cluster + all its state).
set -euo pipefail
kind delete cluster --name code-server-work
echo "✅ Deleted kind cluster 'code-server-work'."
