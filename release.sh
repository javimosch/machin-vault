#!/bin/sh
# Build the RELEASE artifact — a different binary from ./build.sh's output.
#
# machin links libssl, libcrypto and libsqlite3 into every binary unless you
# pass --static, which puts a glibc floor on it: it would not start on Debian
# 11, Ubuntu 20.04, RHEL 8, Alpine, or a slim container. machin-vault published
# no binary at all until now — the only documented way in was ./build.sh, which
# needs the machin toolchain. See https://github.com/javimosch/stranger
#
# This RUNS build.sh rather than re-deriving the source list, because the build
# is two-stage: a wasm client, then a python codegen step that writes
# src/host_gen.src, then the native link. Re-deriving it got an incomplete list
# and a link error (undefined reference to `api_backup`) — the source of truth
# for what goes into this binary is build.sh, so use it.
set -e
cd "$(dirname "$0")"
MACHIN="${MACHIN:-machin}"
./build.sh
"$MACHIN" build vault.mfl -o machin-vault-linux-x86_64 --static
LDD_OUT=$(ldd machin-vault-linux-x86_64 2>&1 || true)   # ldd exits 1 on a static binary
case "$(file machin-vault-linux-x86_64)" in *"statically linked"*) ;; *) echo "not static — refusing"; exit 1 ;; esac
case "$LDD_OUT" in *"not a dynamic executable"*) ;; *) echo "has dynamic deps — refusing: $LDD_OUT"; exit 1 ;; esac
./machin-vault-linux-x86_64 help-json >/dev/null 2>&1 || { echo "release binary does not run — refusing"; exit 1; }
echo "release ok: $(wc -c < machin-vault-linux-x86_64) bytes, static"
