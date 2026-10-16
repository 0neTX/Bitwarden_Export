#!/usr/bin/env bash
# Test harness for the PING_URL helpers in root/usr/local/lib/bw-export/ping.sh.
#
# entrypoint.sh cannot be sourced to test this: it runs the container entrypoint
# on the way past and expects su, pkill, shoutrrr and 10-adduser to exist. So the
# URL building is a pure function in a file of its own, which this sources
# directly. Only the curl call is left uncovered here, and it is driven through a
# mock below.
#
# Each case is deliberately a subshell so PING_URL and the mock's PATH cannot
# leak into the next one, which is what SC2030/SC2031 flag. The library is
# sourced through $LIB so the control run can point at another implementation,
# and a non-literal path is what SC1091 flags; it is passed to shellcheck as an
# input of its own in ci.yml.
# shellcheck disable=SC1091,SC2030,SC2031
SP="$(cd "$(dirname "$0")" && pwd)"
LIB="${LIB:-$SP/../root/usr/local/lib/bw-export/ping.sh}"
SBX="$SP/sbx/ping"
pass=0; fail=0

# shellcheck source=../root/usr/local/lib/bw-export/ping.sh
. "$LIB"

eq() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  -- expected '$2', got '$3'"; fail=$((fail+1)); fi
}

HC="https://hc-ping.com/0d1e2f"
KUMA="https://kuma.example.com/api/push/abc123"

echo "=== P1: no placeholder, value appended as a path segment ==="
eq "start"        "$HC/start" "$(build_ping_url "$HC" start)"
eq "success"      "$HC/0"     "$(build_ping_url "$HC" success)"
eq "failure"      "$HC/3"     "$(build_ping_url "$HC" failure 3)"
eq "signal code"  "$HC/143"   "$(build_ping_url "$HC" failure 143)"

echo "=== P2: trailing slash never doubles ==="
eq "start"   "$HC/start" "$(build_ping_url "$HC/" start)"
eq "success" "$HC/0"     "$(build_ping_url "$HC/" success)"
eq "failure" "$HC/3"     "$(build_ping_url "$HC/" failure 3)"

echo "=== P3: {code} substituted in place ==="
eq "start"           "$HC/start"       "$(build_ping_url "$HC/{code}" start)"
eq "success"         "$HC/0"           "$(build_ping_url "$HC/{code}" success)"
eq "failure"         "$HC/3"           "$(build_ping_url "$HC/{code}" failure 3)"
eq "mid-URL"         "$HC/3/extra"     "$(build_ping_url "$HC/{code}/extra" failure 3)"
eq "every occurrence" "$HC/3?dup=3"    "$(build_ping_url "$HC/{code}?dup={code}" failure 3)"
eq "no segment added" "$HC/{x}/0"      "$(build_ping_url "$HC/{x}/{code}" success)"

echo "=== P4: {status} speaks up/down and has no start ==="
eq "start omitted" ""                        "$(build_ping_url "$KUMA?status={status}" start)"
eq "success"       "$KUMA?status=up"         "$(build_ping_url "$KUMA?status={status}" success)"
eq "failure"       "$KUMA?status=down"       "$(build_ping_url "$KUMA?status={status}" failure 3)"
eq "no segment added" "$KUMA?status=up"      "$(build_ping_url "$KUMA?status={status}" success)"

echo "=== P5: both placeholders ==="
eq "start omitted" "" \
   "$(build_ping_url "$KUMA?status={status}&msg=exit-{code}" start)"
eq "success"       "$KUMA?status=up&msg=exit-0" \
   "$(build_ping_url "$KUMA?status={status}&msg=exit-{code}" success)"
eq "failure"       "$KUMA?status=down&msg=exit-3" \
   "$(build_ping_url "$KUMA?status={status}&msg=exit-{code}" failure 3)"

echo "=== P6: nothing to ping ==="
eq "empty base"     "" "$(build_ping_url "" success)"
eq "unset base"     "" "$(build_ping_url "${undefined_on_purpose:-}" failure 1)"
eq "unknown event"  "" "$(build_ping_url "$HC" finished)"

echo "=== P7: send_ping drives curl ==="
rm -rf "$SBX"; mkdir -p "$SBX/bin"
cat > "$SBX/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
exit "${CURL_EXIT:-0}"
MOCK
chmod +x "$SBX/bin/curl"
export CURL_LOG="$SBX/calls"
: > "$CURL_LOG"

( export PATH="$SBX/bin:$PATH" PING_URL="$HC"
  send_ping success 0 ) > "$SBX/out" 2>&1
eq "called once"      "1"         "$(wc -l < "$CURL_LOG")"
eq "pinged the right URL" "0" \
   "$(grep -cq -- "$HC/0" "$CURL_LOG"; echo $?)"
eq "bounded and retried"  "0" \
   "$(grep -q -- "--max-time 10" "$CURL_LOG" && grep -q -- "--retry 3" "$CURL_LOG"; echo $?)"
eq "logged the event, not the URL" "0" \
   "$(grep -q "Monitoring ping: success" "$SBX/out" && ! grep -q "0d1e2f" "$SBX/out"; echo $?)"

echo "=== P8: a ping is never allowed to fail the run ==="
: > "$CURL_LOG"
rc=$( export PATH="$SBX/bin:$PATH" PING_URL="$HC" CURL_EXIT=22
      send_ping failure 3 > "$SBX/out" 2>&1; echo $? )
eq "send_ping still returns 0" "0" "$rc"
eq "warned without the URL" "0" \
   "$(grep -q "monitoring ping (failure) failed" "$SBX/out" && ! grep -q "0d1e2f" "$SBX/out"; echo $?)"

# The guard for #22: entrypoint.sh pings from an EXIT trap, and send_notification
# leaves "set -e" on in that shell. If the curl failure were ever allowed to
# escape, the container would exit with curl's status instead of the export's.
( export PATH="$SBX/bin:$PATH" PING_URL="$HC" CURL_EXIT=22
  set -e; send_ping failure 3 >/dev/null 2>&1; exit 3 )
rc=$?
eq "exit code stays the export's" "3" "$rc"

echo "=== P9: unset PING_URL does nothing at all ==="
: > "$CURL_LOG"
( export PATH="$SBX/bin:$PATH"; unset PING_URL
  send_ping start; send_ping success 0 ) > "$SBX/out" 2>&1
eq "curl never called" "0"  "$(wc -c < "$CURL_LOG")"
eq "nothing logged"    "0"  "$(wc -c < "$SBX/out")"

rm -rf "$SBX"
echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
