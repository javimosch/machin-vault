#!/usr/bin/env bash
# Build machin-vault: one wasm client (the reactive dashboard) + one native binary
# that is BOTH the agent-first CLI and the server that serves the wasm. Needs machin
# v0.82.0+ and zig (the C->wasm compiler). Frameworks are vendored under src/.
set -euo pipefail
cd "$(dirname "$0")"
MACHIN="${MACHIN:-machin}"
command -v "$MACHIN" >/dev/null 2>&1 || { echo "error: '$MACHIN' not found (set MACHIN=/path/to/machin)"; exit 1; }

# 1. stylesheet: machin-web-ui's Tailwind engine scans the app + components.
MWU="${MACHIN_WEB_UI:-machin-web-ui}"
command -v "$MWU" >/dev/null 2>&1 || { echo "error: '$MWU' not found (set MACHIN_WEB_UI=/path/to/machin-web-ui)"; exit 1; }
"$MWU" css src components -o web/tw.css

# 2. wasm CLIENT: reactive runtime + shared models + the client component.
"$MACHIN" encode src/reactive.src src/models.src src/client.src > client.mfl
"$MACHIN" build client.mfl --target wasm -o app.wasm
echo "built ./app.wasm ($(wc -c < app.wasm) bytes)"

# 3. embed the JS host + stylesheet (MFL string escaping == JSON's ASCII escapes).
python3 - <<'PY' > src/host_gen.src
import functools, json
json.dumps = functools.partial(json.dumps, ensure_ascii=False)
print('func host_js() (s) { s = ' + json.dumps(open('web/host.js').read()) + ' }')
print('func tw_css_text() (s) { s = ' + json.dumps(open('web/tw.css').read()) + ' }')
PY

# 4. native BINARY: CLI (flags/vault/ops) + server (machweb + machin-web-ui components) + UI host.
"$MACHIN" encode \
    src/flags.src src/vault.src src/ops.src src/telemetry.src \
    src/machweb.src components/*.src src/models.src src/server.src src/host_gen.src \
    src/main.src > vault.mfl
"$MACHIN" build vault.mfl -o machin-vault
echo "built ./machin-vault"
echo "cli:    ./machin-vault help-json"
echo "daemon: ./machin-vault -c vault.json serve --port 8080"
