#!/usr/bin/env bash
# Local NEO stack: Anvil + contracts + console.
#   scripts/dev.sh            start everything (console on http://127.0.0.1:5173)
#   scripts/dev.sh stop       stop anvil and the static server
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"

if [ "${1:-}" = "stop" ]; then
  pkill -f "anvil --port 8545" 2>/dev/null || true
  pkill -f "http.server 5173" 2>/dev/null || true
  echo stopped; exit 0
fi

if ! pgrep -f "anvil --port 8545" >/dev/null; then
  anvil --port 8545 --block-time 2 --silent > .anvil.log 2>&1 &
  for _ in $(seq 1 50); do
    cast chain-id --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1 && break
    sleep 0.2
  done
fi

forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -q >/dev/null
echo "deployed: $(tr -d '\n ' < app/deployments.local.json)"

if ! pgrep -f "http.server 5173" >/dev/null; then
  (cd app && python3 -m http.server 5173 --bind 127.0.0.1 > ../.http.log 2>&1 &)
fi
echo "console: http://127.0.0.1:5173"
wait
