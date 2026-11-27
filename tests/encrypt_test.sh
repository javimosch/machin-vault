#!/usr/bin/env bash
# e2e tests for per-target age encryption. Needs: ./machin-vault built, bash.
# The age-dependent cases run only when `age` + `age-keygen` are on PATH.
#   tests/encrypt_test.sh            (from the repo root)
set -uo pipefail
export DO_NOT_TRACK=1
BIN="$(cd "$(dirname "$0")/.." && pwd)/machin-vault"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
expect_code() { local want=$1; shift; "$@" >"$W/out" 2>"$W/err"; local got=$?; [ "$got" = "$want" ] && ok "$desc (exit $got)" || bad "$desc: want $want got $got :: $(cat "$W/err")"; }

SECRET="TOP-SECRET-$RANDOM-$RANDOM"
printf '%s\n' "$SECRET" > "$W/data.txt"
HAVE_AGE=0; command -v age >/dev/null && command -v age-keygen >/dev/null && HAVE_AGE=1
if [ $HAVE_AGE = 1 ]; then
  age-keygen -o "$W/id.txt" 2>/dev/null; R1=$(age-keygen -y "$W/id.txt")
  age-keygen -o "$W/id2.txt" 2>/dev/null; R2=$(age-keygen -y "$W/id2.txt")
else
  R1="age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"; R2="$R1"
fi

cfg() { # $1 = targets json
  printf '{"store":"%s/store","targets":[%s]}' "$W" "$1" > "$W/vault.json"; }
ENC_T="{\"name\":\"sec\",\"kind\":\"custom\",\"command\":\"cat $W/data.txt | gzip\",\"restore\":\"gunzip > $W/restored.txt\",\"ext\":\"txt.gz\",\"retention\":2,\"encrypt\":\"age\",\"age_recipients\":[\"$R1\",\"$R2\"]}"
PLAIN_T="{\"name\":\"pub\",\"kind\":\"custom\",\"command\":\"cat $W/data.txt | gzip\",\"ext\":\"txt.gz\"}"
V="$BIN -c $W/vault.json"

# --- validation (no age needed) ---
cfg "{\"name\":\"x\",\"kind\":\"custom\",\"command\":\"echo hi\",\"encrypt\":\"age\",\"age_recipients\":[]}"
desc="encrypt=age without recipients refused"; expect_code 80 $V backup x
cfg "{\"name\":\"x\",\"kind\":\"custom\",\"command\":\"echo hi\",\"encrypt\":\"rot13\",\"age_recipients\":[\"$R1\"]}"
desc="unknown encrypt value refused"; expect_code 80 $V backup x
cfg "{\"name\":\"x\",\"kind\":\"file\",\"source\":\"$W/data.txt\",\"encrypt\":\"age\",\"age_recipients\":[\"$R1\"]}"
desc="encrypt on kind=file refused"; expect_code 80 $V backup x
cfg "{\"name\":\"x\",\"kind\":\"custom\",\"command\":\"echo hi\",\"encrypt\":\"age\",\"age_recipients\":[\"ssh-rsa AAA\"]}"
desc="non-age1 recipient refused"; expect_code 80 $V backup x
[ ! -e "$W/store/x" ] || [ -z "$(ls -A "$W/store/x" 2>/dev/null)" ] && ok "nothing written on refusal" || bad "files written on refusal: $(ls -A "$W/store/x")"

# --- age binary missing: refused before the dump, nothing written ---
cfg "$ENC_T"
desc="missing age binary refused"; expect_code 90 env PATH=/usr/bin/../nonexistent:/bin/nonexistent "$BIN" -c "$W/vault.json" backup sec 2>/dev/null || true
if [ $HAVE_AGE = 0 ]; then
  desc="missing age binary refused (real PATH)"; expect_code 90 $V backup sec
fi
[ -z "$(ls -A "$W/store/sec" 2>/dev/null)" ] && ok "no artifact without age" || bad "artifact written without age"

# --- plaintext target unchanged (regression) ---
cfg "$PLAIN_T"
desc="plain target backs up"; expect_code 0 $V backup pub
ls "$W/store/pub/" | grep -qE '^pub_[0-9]+_[0-9a-f]{12}\.txt\.gz$' && ok "plain artifact name unchanged" || bad "plain name: $(ls "$W/store/pub")"
$V list pub | grep -q '"encrypted":false,"cipher":""' && ok "list: plain shows encrypted=false" || bad "list plain: $(cat "$W/out")"

if [ $HAVE_AGE = 0 ]; then
  echo "SKIP age round-trip cases (age not installed)"; echo "pass=$pass fail=$fail"; [ $fail = 0 ]; exit
fi

# --- encrypted round-trip ---
cfg "$ENC_T,$PLAIN_T"
desc="encrypted backup"; expect_code 0 $V backup sec
f=$(ls "$W/store/sec/" | grep -v '^\.' )
echo "$f" | grep -qE '^sec_[0-9]+_[0-9a-f]{12}\.txt\.gz\.age$' && ok "artifact ends .age" || bad "name: $f"
[ -z "$(ls -A "$W/store/sec" | grep '^\.tmp-')" ] && ok "no temp dir left" || bad "temp dir left"
grep -rqa "$SECRET" "$W/store" /tmp/mv-* 2>/dev/null && bad "PLAINTEXT FOUND on disk" || ok "no plaintext in store or /tmp"
zcat "$W/store/sec/$f" 2>/dev/null | grep -qa "$SECRET" && bad "artifact is not encrypted" || ok "artifact not readable without key"
desc="unchanged content skipped"; expect_code 0 $V backup sec
grep -q '"skipped":true' "$W/out" && ok "skip reported" || bad "no skip: $(cat "$W/out")"
$V list sec | grep -q '"encrypted":true,"cipher":"age"' && ok "list shows cipher=age" || bad "list enc"

desc="unpack without identity refused"; expect_code 80 env -u MACHIN_VAULT_AGE_IDENTITY $V unpack sec --to "$W/u0"
desc="unpack with --identity"; expect_code 0 $V unpack sec --to "$W/u1" --identity "$W/id.txt"
grep -q "$SECRET" "$W/u1/"*.txt && ok "unpack round-trip" || bad "unpack content"
desc="unpack with env + 2nd recipient"; expect_code 0 env MACHIN_VAULT_AGE_IDENTITY="$W/id2.txt" $V unpack sec --to "$W/u2"
desc="unpack with wrong identity fails"; age-keygen -o "$W/wrong.txt" 2>/dev/null; expect_code 100 $V unpack sec --to "$W/u3" --identity "$W/wrong.txt"
desc="restore streams decrypt"; expect_code 0 $V restore sec --yes --identity "$W/id.txt"
grep -q "$SECRET" "$W/restored.txt" && ok "restore round-trip" || bad "restore content"
desc="get copies ciphertext"; expect_code 0 $V get sec --to "$W/g"
grep -q '"cipher":"age"' "$W/out" && ok "get reports cipher" || bad "get"

# --- truncation detected ---
cp "$W/store/sec/$f" "$W/trunc.age"; head -c 100 "$W/trunc.age" > "$W/store/sec/$f"
desc="truncated artifact fails loudly"; expect_code 100 $V unpack sec --to "$W/u4" --identity "$W/id.txt"
cp "$W/trunc.age" "$W/store/sec/$f"

# --- failing dump: nothing written ---
cfg "{\"name\":\"sec\",\"kind\":\"custom\",\"command\":\"cat /nonexistent\",\"encrypt\":\"age\",\"age_recipients\":[\"$R1\"]}"
n=$(ls "$W/store/sec" | wc -l)
desc="failing dump"; expect_code 100 $V backup sec
[ "$(ls -A "$W/store/sec" | wc -l)" = "$n" ] && ok "failing dump leaves nothing" || bad "leftovers: $(ls -A "$W/store/sec")"
cfg "{\"name\":\"sec\",\"kind\":\"custom\",\"command\":\"true\",\"encrypt\":\"age\",\"age_recipients\":[\"$R1\"]}"
desc="empty dump refused"; expect_code 100 $V backup sec

# --- retention across versions ---
cfg "$ENC_T"
for i in 1 2 3; do echo "$i" >> "$W/data.txt"; sleep 1; $V backup sec >/dev/null 2>&1; done
[ "$(ls "$W/store/sec" | grep -c '\.age$')" = 2 ] && ok "retention keeps 2" || bad "retention: $(ls "$W/store/sec")"

echo "pass=$pass fail=$fail"; [ $fail = 0 ]
