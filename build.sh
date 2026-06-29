#!/usr/bin/env bash
# Build machin-vault: one wasm client (the reactive dashboard) + one native binary
# that is BOTH the agent-first CLI and the server that serves the wasm. Needs machin
# v0.82.0+ and zig (the C->wasm compiler). Frameworks are vendored under src/.
set -euo pipefail
cd "$(dirname "$0")"
MACHIN="${MACHIN:-machin}"
command -v "$MACHIN" >/dev/null 2>&1 || { echo "error: '$MACHIN' not found (set MACHIN=/path/to/machin)"; exit 1; }

# 1. wasm CLIENT: reactive runtime + shared models + the client component.
"$MACHIN" encode src/reactive.src src/models.src src/client.src > client.mfl
"$MACHIN" build client.mfl --target wasm -o app.wasm
echo "built ./app.wasm ($(wc -c < app.wasm) bytes)"

# 2. embed the generic JS host as host_js() (JSON escaping == MFL string escaping).
python3 - <<'PY' > src/host_gen.src
import json
print('func host_js() (s) { s = ' + json.dumps(open('web/host.js').read()) + ' }')
PY

# 3. native BINARY: CLI (flags/vault/ops) + server (machweb/styles/server) + UI host.
"$MACHIN" encode \
    src/flags.src src/vault.src src/ops.src \
    src/machweb.src src/models.src src/styles.src src/server.src src/host_gen.src \
    src/main.src > vault.mfl
"$MACHIN" build vault.mfl -o machin-vault
echo "built ./machin-vault"
echo "cli:    ./machin-vault help-json"
echo "daemon: ./machin-vault -c vault.json serve --port 8080"
