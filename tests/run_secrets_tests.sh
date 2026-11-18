#!/usr/bin/env bash
# Test harness for root/usr/local/lib/bw-export/secrets.sh (resolve_secret).
# Runs with set -u enabled to verify undefined-variable safety.
# shellcheck disable=SC1091,SC2030,SC2031
set -u

SP="$(cd "$(dirname "$0")" && pwd)"
LIB="${LIB:-$SP/../root/usr/local/lib/bw-export/secrets.sh}"
SBX="$SP/sbx/secrets"
pass=0; fail=0

# shellcheck source=../root/usr/local/lib/bw-export/secrets.sh
. "$LIB"

eq() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  -- expected '$2', got '$3'"; fail=$((fail+1)); fi
}

rm -rf "$SBX"; mkdir -p "$SBX"

echo "=== S1: unset variable under set -u ==="
( unset SECRET_VAR; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); echo "rc=$? out=$out" ) > "$SBX/res"
eq "returns 0 and empty" "rc=0 out=" "$(cat "$SBX/res")"
eq "no warning"          ""          "$(cat "$SBX/err")"

echo "=== S2: empty variable ==="
( SECRET_VAR=""; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); echo "rc=$? out=$out" ) > "$SBX/res"
eq "returns 0 and empty" "rc=0 out=" "$(cat "$SBX/res")"
eq "no warning"          ""          "$(cat "$SBX/err")"

echo "=== S3: literal value ==="
( SECRET_VAR="telegram://tok123@telegram/?channels=42"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "exact literal" "telegram://tok123@telegram/?channels=42" "$(cat "$SBX/val")"
eq "no warning"    ""                                        "$(cat "$SBX/err")"

echo "=== S4: file without trailing newline ==="
printf 'telegram://filetok@telegram/?channels=1' > "$SBX/s4"
( SECRET_VAR="$SBX/s4"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "file value" "telegram://filetok@telegram/?channels=1" "$(cat "$SBX/val")"
eq "no warning" ""                                        "$(cat "$SBX/err")"

echo "=== S5: file with trailing newline and CRLF ==="
printf 'https://hc-ping.com/uuid-123\r\n' > "$SBX/s5"
( SECRET_VAR="$SBX/s5"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "stripped CR/LF" "https://hc-ping.com/uuid-123" "$(cat "$SBX/val")"

echo "=== S6: multi-line file takes first non-empty line ==="
printf '\n  \nhttps://hc-ping.com/first-line\nignored-second-line\n' > "$SBX/s6"
( SECRET_VAR="$SBX/s6"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "first non-empty line" "https://hc-ping.com/first-line" "$(cat "$SBX/val")"

echo "=== S7: empty file returns empty and warns ==="
: > "$SBX/empty"
( SECRET_VAR="$SBX/empty"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "empty output"  ""  "$(cat "$SBX/val")"
eq "warns empty"   "1" "$(grep -c 'empty file' "$SBX/err")"

echo "=== S8: unreadable file returns empty and warns ==="
printf 'secret\n' > "$SBX/unreadable"
chmod 000 "$SBX/unreadable"
if [ "$(id -u)" -ne 0 ]; then
  ( SECRET_VAR="$SBX/unreadable"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
  eq "empty output"     ""  "$(cat "$SBX/val")"
  eq "warns unreadable" "1" "$(grep -c 'cannot be read' "$SBX/err")"
else
  echo "  SKIP  2 assertions: root reads any file, so it cannot be made unreadable"
fi
chmod 600 "$SBX/unreadable"

echo "=== S9: an unmounted /run/secrets path is empty, never a literal ==="
( SECRET_VAR="/run/secrets/SECRET-missing-tok"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "empty output"           ""  "$(cat "$SBX/val")"
eq "warns not mounted"      "1" "$(grep -c 'not mounted' "$SBX/err")"
eq "value not in warning"   "0" "$(grep -c 'SECRET-missing-tok' "$SBX/err")"

echo "=== S10: directory path returns empty and warns ==="
mkdir -p "$SBX/adir"
( SECRET_VAR="$SBX/adir"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "empty output"    ""  "$(cat "$SBX/val")"
eq "warns not file"  "1" "$(grep -c 'not a regular file' "$SBX/err")"

echo "=== S11: special characters preserved verbatim ==="
# shellcheck disable=SC2016
printf ' master "pw" $HOME \\x \n' > "$SBX/special"
( SECRET_VAR="$SBX/special"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
# shellcheck disable=SC2016
eq "special chars intact" ' master "pw" $HOME \x ' "$(cat "$SBX/val")"

echo "=== S12: set -x trace does not leak resolved secret ==="
printf 'SUPER-SECRET-TOKEN-999\n' > "$SBX/traced"
( export SECRET_VAR="$SBX/traced"; set -x; resolve_secret SECRET_VAR >/dev/null ) > "$SBX/trace" 2>&1
eq "token not in trace" "0" "$(grep -c 'SUPER-SECRET-TOKEN-999' "$SBX/trace")"

echo "=== S13: a literal that starts with / is used as is, without a warning ==="
( SECRET_VAR="/Passw0rd"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "literal kept" "/Passw0rd" "$(cat "$SBX/val")"
eq "no warning"   ""          "$(cat "$SBX/err")"

echo "=== S14: a missing file in a folder that exists warns, and the value is kept ==="
( SECRET_VAR="$SBX/SECRET-typo-file"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "literal kept"         "$SBX/SECRET-typo-file" "$(cat "$SBX/val")"
eq "warns not found"      "1" "$(grep -c 'was not found' "$SBX/err")"
eq "value not in warning" "0" "$(grep -c 'SECRET-typo-file' "$SBX/err")"

echo "=== S15: NAME_FILE is read, without its CRLF ==="
printf 'SECRET-from-file\r\n' > "$SBX/s15"
( SECRET_VAR_FILE="$SBX/s15"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "file value" "SECRET-from-file" "$(cat "$SBX/val")"
eq "no warning" ""                 "$(cat "$SBX/err")"

echo "=== S16: NAME and NAME_FILE both set: nothing, and a warning ==="
( SECRET_VAR="SECRET-literal"; SECRET_VAR_FILE="$SBX/s15"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "empty output"         ""  "$(cat "$SBX/val")"
eq "warns both set"       "1" "$(grep -c 'SECRET_VAR and SECRET_VAR_FILE are both set' "$SBX/err")"
eq "value not in warning" "0" "$(grep -c 'SECRET-' "$SBX/err")"

echo "=== S17: NAME_FILE is always a path: a missing one is reported, wherever it is ==="
( SECRET_VAR_FILE="/nonexistent-dir/SECRET-x"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "empty output"         ""  "$(cat "$SBX/val")"
eq "warns does not exist" "1" "$(grep -c 'SECRET_VAR_FILE points to a file that does not exist' "$SBX/err")"
eq "path not in warning"  "0" "$(grep -c 'SECRET-x' "$SBX/err")"

echo "=== S18: NAME_FILE empty or a folder: nothing, and a warning ==="
( SECRET_VAR_FILE="$SBX/empty"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "empty file: empty output" "" "$(cat "$SBX/val")"
eq "empty file: warns"        "1" "$(grep -c 'SECRET_VAR_FILE points to an empty file' "$SBX/err")"
( SECRET_VAR_FILE="$SBX/adir"; out=$(resolve_secret SECRET_VAR 2>"$SBX/err"); printf '%s' "$out" > "$SBX/val" )
eq "folder: empty output"     "" "$(cat "$SBX/val")"
eq "folder: warns"            "1" "$(grep -c 'SECRET_VAR_FILE points to a path that is not a regular file' "$SBX/err")"

echo "=== S19: secret_is_set sees NAME or NAME_FILE ==="
eq "neither"   "1" "$( ( unset SECRET_VAR SECRET_VAR_FILE; secret_is_set SECRET_VAR ); echo $?)"
eq "NAME"      "0" "$( ( SECRET_VAR=x; unset SECRET_VAR_FILE; secret_is_set SECRET_VAR ); echo $?)"
eq "NAME_FILE" "0" "$( ( unset SECRET_VAR; SECRET_VAR_FILE=/x; secret_is_set SECRET_VAR ); echo $?)"
eq "both empty" "1" "$( ( SECRET_VAR=; SECRET_VAR_FILE=; secret_is_set SECRET_VAR ); echo $?)"

echo "=== S20: set -x trace does not leak a value read through NAME_FILE ==="
printf 'SUPER-SECRET-FILE-TOKEN\n' > "$SBX/s20"
( export SECRET_VAR_FILE="$SBX/s20"; set -x; resolve_secret SECRET_VAR >/dev/null ) > "$SBX/trace" 2>&1
eq "token not in trace" "0" "$(grep -c 'SUPER-SECRET-FILE-TOKEN' "$SBX/trace")"

echo ""
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
