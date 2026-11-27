#!/usr/bin/env bash
# e2e tests for per-target secrets (env injection). Needs ./machin-vault built.
#   tests/secrets_test.sh            (from the repo root)
set -uo pipefail
export DO_NOT_TRACK=1
BIN="$(cd "$(dirname "$0")/.." && pwd)/machin-vault"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
expect_code() { local want=$1; shift; "$@" >"$W/out" 2>"$W/err"; local got=$?; [ "$got" = "$want" ] && ok "$desc (exit $got)" || bad "$desc: want $want got $got :: $(cat "$W/err")"; }

SECRET="pw-$RANDOM$RANDOM-s3cr3t"
mkdir -p "$W/sec"
printf '%s\n' "$SECRET" > "$W/sec/pw"; chmod 600 "$W/sec/pw"
V="$BIN -c $W/vault.json"
cfg() { printf '{"store":"%s/store","targets":[%s]}' "$W" "$1" > "$W/vault.json"; }
tgt() { # name, secrets-json, command, [extra]
  printf '{"name":"%s","kind":"custom","ext":"txt.gz","secrets":%s,"command":"%s"%s}' "$1" "$2" "$3" "${4:-}"; }
FILE_S="[{\"env\":\"MV_PW\",\"from\":\"file:$W/sec/pw\"}]"
DUMP='printf %s \"$MV_PW\" | gzip'

# --- value reaches the child, never the config / output / argv ---
cfg "$(tgt t "$FILE_S" "sleep 2; $DUMP" ",\"restore\":\"gunzip > $W/restored; printf %s \\\"\$MV_PW\\\" > $W/restored-env\"")"
grep -q "$SECRET" "$W/vault.json" && bad "secret in vault.json" || ok "secret not in vault.json"
$V backup t >"$W/out" 2>"$W/err" & bp=$!
sleep 1
ps -eo args | grep -v grep | grep -q "$SECRET" && bad "SECRET VISIBLE IN ps" || ok "secret not in any argv (ps)"
wait $bp; [ $? = 0 ] && ok "backup with file secret (exit 0)" || bad "backup failed: $(cat "$W/err")"
grep -q "$SECRET" "$W/out" "$W/err" && bad "secret in machin-vault output" || ok "secret not in output"
desc="unpack"; expect_code 0 $V unpack t --to "$W/u"
[ "$(cat "$W/u/"*.txt)" = "$SECRET" ] && ok "child received the exact value (trailing newline stripped)" || bad "value mismatch: $(cat "$W/u/"*.txt)"
desc="restore gets secret too"; expect_code 0 $V restore t --yes
[ "$(cat "$W/restored-env")" = "$SECRET" ] && ok "restore env has value" || bad "restore env"

# --- env: source ---
cfg "$(tgt e "[{\"env\":\"MV_PW\",\"from\":\"env:SRC_PW\"}]" "$DUMP")"
desc="env: source"; expect_code 0 env SRC_PW="$SECRET" $V backup e
desc="env: source unset refused"; expect_code 80 env -u SRC_PW $V backup e

# --- refusals happen before the dump, nothing written ---
chmod 644 "$W/sec/pw"
cfg "$(tgt m "$FILE_S" "$DUMP")"
desc="world-readable secret file refused"; expect_code 80 $V backup m
chmod 600 "$W/sec/pw"
cfg "$(tgt m "[{\"env\":\"MV_PW\",\"from\":\"file:$W/sec/missing\"}]" "$DUMP")"
desc="missing secret file"; expect_code 90 $V backup m
cfg "$(tgt m "[{\"env\":\"mv-pw\",\"from\":\"file:$W/sec/pw\"}]" "$DUMP")"
desc="bad env name refused"; expect_code 80 $V backup m
cfg "$(tgt m "[{\"env\":\"MV_PW\",\"from\":\"vault:x\"}]" "$DUMP")"
desc="unknown source refused"; expect_code 80 $V backup m
cfg "$(tgt m "[{\"env\":\"MV_PW\",\"from\":\"file:relative/pw\"}]" "$DUMP")"
desc="relative path refused"; expect_code 80 $V backup m
[ -z "$(ls -A "$W/store/m" 2>/dev/null)" ] && ok "nothing written on refusal" || bad "files on refusal: $(ls -A "$W/store/m")"
install -m 600 /dev/null "$W/sec/empty"
cfg "$(tgt m "[{\"env\":\"MV_PW\",\"from\":\"file:$W/sec/empty\"}]" "$DUMP")"
desc="empty secret file fails"; expect_code 100 $V backup m

# --- redaction of child stderr ---
cfg "$(tgt r "$FILE_S" 'echo \"auth failed for $MV_PW\" >&2; exit 1')"
desc="failing command"; expect_code 100 $V backup r
grep -q "$SECRET" "$W/err" && bad "secret leaked in error" || ok "error redacted"
grep -q '\*\*\*' "$W/err" && ok "redaction marker present" || bad "no marker: $(cat "$W/err")"

# --- secrets + age encryption together ---
if command -v age >/dev/null && command -v age-keygen >/dev/null; then
  age-keygen -o "$W/id.txt" 2>/dev/null; R=$(age-keygen -y "$W/id.txt")
  cfg "$(tgt a "$FILE_S" "$DUMP" ",\"encrypt\":\"age\",\"age_recipients\":[\"$R\"]")"
  desc="age + secret backup"; expect_code 0 $V backup a
  desc="age + secret unpack"; expect_code 0 $V unpack a --to "$W/ua" --identity "$W/id.txt"
  [ "$(cat "$W/ua/"*.txt)" = "$SECRET" ] && ok "age + secret round-trip" || bad "age+secret value"
  grep -rqa "$SECRET" "$W/store" && bad "plaintext secret in store" || ok "no plaintext in store"
else
  echo "SKIP age + secrets (age not installed)"
fi

# --- guide documents it ---
$BIN guide | grep -q '"secrets (per target)"' && ok "guide documents secrets" || bad "guide missing secrets"
$BIN help-json | grep -q '"secrets"' && ok "help-json documents secrets" || bad "help-json missing secrets"

echo "pass=$pass fail=$fail"; [ $fail = 0 ]
