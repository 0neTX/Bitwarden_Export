#!/usr/bin/env bash
# Test harness for the NOTIFICATION_URL helper in
# root/usr/local/lib/bw-export/notify.sh, sourced directly for the same reason as
# run_ping_tests.sh. shoutrrr is replaced by a stub that records its argv, the
# URL it was handed through the environment and the message, and that can fail
# the way the real one does, with the address on stderr.
#
# Each case is a subshell so NOTIFICATION_URL cannot leak into the next one
# (SC2030/SC2031). The library path is not a literal, which SC1091 flags; it is
# passed to shellcheck as an input of its own in ci.yml.
# shellcheck disable=SC1091,SC2030,SC2031
SP="$(cd "$(dirname "$0")" && pwd)"
export LOG_LIB="$SP/../root/usr/local/lib/bw-export/log.sh"
LIB="${LIB:-$SP/../root/usr/local/lib/bw-export/notify.sh}"
SBX="$SP/sbx/notify"
pass=0; fail=0

# shellcheck source=../root/usr/local/lib/bw-export/notify.sh
. "$LIB"

eq() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  -- expected '$2', got '$3'"; fail=$((fail+1)); fi
}

rm -rf "$SBX"; mkdir -p "$SBX"
cat > "$SBX/shoutrrr" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "$d/argv"
printf '%s\n' "${SHOUTRRR_URL-<unset>}" >> "$d/envurl"
while [ $# -gt 0 ]; do [ "$1" = -m ] && { printf '%s' "$2" > "$d/message"; shift; }; shift; done
if [ -n "${STUB_FAIL:-}" ]; then
  echo "telegram: failed to send: Post \"https://api.telegram.org/bot${SHOUTRRR_URL#telegram://}/sendMessage\": dial tcp" >&2
  exit 69
fi
echo "Notification sent"
STUB
chmod +x "$SBX/shoutrrr"
export SHOUTRRR_BIN="$SBX/shoutrrr"
URL="telegram://123456:SECRET-bot-token@telegram?chats=42"
reset() { rm -f "$SBX/argv" "$SBX/envurl" "$SBX/message" "$SBX/out"; }

echo "=== N1: no NOTIFICATION_URL, nothing is sent ==="
reset
( unset NOTIFICATION_URL; send_message "hello"; echo "rc=$?" ) > "$SBX/out" 2>&1
eq "returns 0"        "rc=0" "$(tail -n 1 "$SBX/out")"
eq "shoutrrr not run" "no"   "$([ -e "$SBX/argv" ] && echo yes || echo no)"

echo "=== N2: the message is delivered, the URL through the environment ==="
reset
( NOTIFICATION_URL="$URL" send_message "Export finished" ) > "$SBX/out" 2>&1
eq "message"            "Export finished" "$(cat "$SBX/message")"
eq "URL in SHOUTRRR_URL" "$URL"           "$(cat "$SBX/envurl")"
eq "token not in argv"  "0"               "$(grep -c SECRET "$SBX/argv")"
eq "no -u flag"         "0"               "$(grep -c -- ' -u ' "$SBX/argv")"
eq "token not logged"   "0"               "$(grep -c SECRET "$SBX/out")"

echo "=== N3: kept out of a set -x trace, as send_notification used to leave it ==="
reset
( export NOTIFICATION_URL="$URL"; set -x; send_message "traced" ) > "$SBX/out" 2>&1
eq "token not in the trace" "0" "$(grep -c SECRET "$SBX/out")"

echo "=== N4: a failing service neither changes the status nor leaks the token ==="
reset
( set -e; NOTIFICATION_URL="$URL" STUB_FAIL=1 send_message "boom"; echo "still running rc=$?" ) > "$SBX/out" 2>&1
eq "returns 0, set -e survives" "still running rc=0" "$(tail -n 1 "$SBX/out")"
eq "warns"                      "1" "$(grep -c 'Sending the notification failed' "$SBX/out")"
eq "error text with the token dropped" "0" "$(grep -c SECRET "$SBX/out")"

echo "=== N5: an empty message is replaced, since Telegram rejects one ==="
reset
( NOTIFICATION_URL="$URL" send_message "" ) > "$SBX/out" 2>&1
eq "non-empty message sent" "Bitwarden/Vaultwarden Export: (no log output to send)" "$(cat "$SBX/message")"

echo "=== N6: a multi-line message arrives intact ==="
reset
msg=$'line one\nline "two" $HOME `x`\n'
( NOTIFICATION_URL="$URL" send_message "$msg" ) > "$SBX/out" 2>&1
eq "verbatim" "${msg}x" "$(cat "$SBX/message"; printf x)"

echo "=== N7: NOTIFICATION_URL as a file path (with trailing newline) ==="
reset
printf '%s\n' "$URL" > "$SBX/notif.secret"
( NOTIFICATION_URL="$SBX/notif.secret" send_message "from file" ) > "$SBX/out" 2>&1
eq "URL resolved in SHOUTRRR_URL" "$URL" "$(cat "$SBX/envurl")"
eq "token not in argv"            "0"    "$(grep -c SECRET "$SBX/argv")"
eq "token not logged"             "0"    "$(grep -c SECRET "$SBX/out")"

echo "=== N8: NOTIFICATION_URL pointing to an empty file does not notify and warns ==="
reset
: > "$SBX/empty.secret"
( NOTIFICATION_URL="$SBX/empty.secret" send_message "skip" ) > "$SBX/out" 2>&1
eq "shoutrrr not run" "no" "$([ -e "$SBX/argv" ] && echo yes || echo no)"
eq "warns empty file" "1"  "$(grep -c 'empty file' "$SBX/out")"

echo "=== N9: NOTIFICATION_URL pointing to an unreadable file does not notify and warns ==="
reset
printf '%s\n' "$URL" > "$SBX/unreadable.secret"
chmod 000 "$SBX/unreadable.secret"
if [ "$(id -u)" -ne 0 ]; then
  ( NOTIFICATION_URL="$SBX/unreadable.secret" send_message "skip" ) > "$SBX/out" 2>&1
  eq "shoutrrr not run" "no" "$([ -e "$SBX/argv" ] && echo yes || echo no)"
  eq "warns unreadable" "1"  "$(grep -c 'cannot be read' "$SBX/out")"
else
  echo "  SKIP  2 assertions: root reads any file, so it cannot be made unreadable"
fi
chmod 600 "$SBX/unreadable.secret"

echo "=== N11: NOTIFICATION_URL_FILE is read ==="
reset
printf '%s\n' "$URL" > "$SBX/notif.file"
( unset NOTIFICATION_URL; NOTIFICATION_URL_FILE="$SBX/notif.file" send_message "via _FILE" ) > "$SBX/out" 2>&1
eq "URL resolved in SHOUTRRR_URL" "$URL" "$(cat "$SBX/envurl")"
eq "token not logged"             "0"    "$(grep -c SECRET "$SBX/out")"

echo "=== N10: NOTIFICATION_URL under /run/secrets but not mounted: no send, a warning ==="
reset
( NOTIFICATION_URL="/run/secrets/no-existe-notif" send_message "missing" ) > "$SBX/out" 2>&1
eq "shoutrrr not run"  "no" "$([ -e "$SBX/argv" ] && echo yes || echo no)"
eq "warns not mounted" "1"  "$(grep -c 'not mounted' "$SBX/out")"

echo "=== N12: NOTIFICATION_LEVEL says which outcomes are wanted ==="
lvl() { ( unset NOTIFICATION_LEVEL; [ "$#" -gt 0 ] && export NOTIFICATION_LEVEL="$1"; notify_level ); }
want() { ( unset NOTIFICATION_LEVEL; [ "$2" != "<unset>" ] && export NOTIFICATION_LEVEL="$2"; notify_wanted "$1" && echo yes || echo no ); }
eq "unset is all"            "all"     "$(lvl)"
eq "empty is all"            "all"     "$(lvl '')"
eq "all"                     "all"     "$(lvl all)"
eq "failure"                 "failure" "$(lvl failure)"
eq "case and spaces ignored" "failure" "$(lvl '  FAILURE ')"
eq "a typo is all"           "all"     "$(lvl failures)"
eq "start, unset"            "yes"     "$(want start '<unset>')"
eq "success, all"            "yes"     "$(want success all)"
eq "start, failure"          "no"      "$(want start failure)"
eq "success, failure"        "no"      "$(want success failure)"
eq "failure, failure"        "yes"     "$(want failure failure)"
eq "failure, all"            "yes"     "$(want failure all)"
eq "success, a typo"         "yes"     "$(want success failures)"

echo "=== N13: only a value that is neither all nor failure warns ==="
warn() { ( unset NOTIFICATION_LEVEL; [ "$#" -gt 0 ] && export NOTIFICATION_LEVEL="$1"; notify_level_warning ); }
eq "unset: silent"   "0" "$(warn | grep -c Warning)"
eq "empty: silent"   "0" "$(warn '' | grep -c Warning)"
eq "all: silent"     "0" "$(warn all | grep -c Warning)"
eq "FAILURE: silent" "0" "$(warn FAILURE | grep -c Warning)"
eq "a typo warns"    "1" "$(warn errors | grep -c 'NOTIFICATION_LEVEL must be all or failure, not "errors"')"
eq "and says all"    "1" "$(warn errors | grep -c 'Sending every notification')"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
