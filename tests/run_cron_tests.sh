#!/usr/bin/env bash
# Test harness for CRON mode and backwards-compatible one-shot execution in
# entrypoint.sh. External binaries (10-adduser, bw_export.sh, supercronic,
# curl, shoutrrr, infisical) are stubbed inside a sandbox directory so the suite
# runs without root, network or containers.
# shellcheck disable=SC2030,SC2031
SP="$(cd "$(dirname "$0")" && pwd)"
ENTRY="${ENTRY:-$SP/../entrypoint.sh}"
SBX="$SP/sbx/cron"
pass=0; fail=0

eq() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  -- expected '$2', got '$3'"; fail=$((fail+1)); fi
}

rm -rf "$SBX"; mkdir -p "$SBX"

cat > "$SBX/adduser" <<'STUB'
#!/usr/bin/env bash
echo "adduser" >> "${CRON_TEST_DIR:?}/calls"
STUB

cat > "$SBX/bw_export.sh" <<'STUB'
#!/usr/bin/env bash
d="${CRON_TEST_DIR:?}"
echo "bw_export:${BW_EXPORT_TAG:-run}" >> "$d/calls"
if [ -n "${BW_EXPORT_SLEEP:-}" ]; then
  trap 'echo "bw_export:got_term" >> "$d/calls"; exit 143' TERM
  sleep "$BW_EXPORT_SLEEP" &
  wait $!
  exit $?
fi
if [ -n "${BW_EXPORT_FAIL_ON_TAG:-}" ] && [ "${BW_EXPORT_TAG:-}" = "$BW_EXPORT_FAIL_ON_TAG" ]; then
  echo "current-run-error-only"
  exit 1
fi
echo "log-line:${BW_EXPORT_TAG:-run}"
exit "${BW_EXPORT_RC:-0}"
STUB

cat > "$SBX/supercronic" <<'STUB'
#!/usr/bin/env bash
d="${CRON_TEST_DIR:?}"
if [ "$1" = "-test" ]; then
  echo "supercronic -test $2" >> "$d/calls"
  [ -n "${SUPERCRONIC_BAD:-}" ] && { echo "invalid crontab" >&2; exit 1; }
  exit 0
fi
echo "supercronic $1" >> "$d/calls"
cp "$1" "$d/seen_crontab"
# Simulate one scheduled tick by extracting the command after either a @macro
# or a 5-field cron schedule.
line=$(head -n 1 "$1")
if [[ "$line" == @* ]]; then
  cmd="${line#* }"
else
  cmd=$(sed -n 's/^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* //p' "$1")
fi
if [ -n "${SUPERCRONIC_HOLD_LOCK:-}" ]; then
  ( flock -x 9; sleep 10 ) 9>"$LOCK_FILE" &
  holder=$!
  sleep 0.2
  BW_EXPORT_TAG=scheduled bash -c "$cmd"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
else
  BW_EXPORT_TAG=scheduled bash -c "$cmd"
fi
STUB

cat > "$SBX/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do :; done
echo "ping:$a" >> "${CRON_TEST_DIR:?}/calls"
STUB

cat > "$SBX/shoutrrr" <<'STUB'
#!/usr/bin/env bash
d="${CRON_TEST_DIR:?}"
while [ $# -gt 0 ]; do [ "$1" = -m ] && { msg="$2"; shift; }; shift; done
printf '%s\n' "$msg" > "$d/last_notify"
echo "notify:$(printf '%s' "$msg" | head -n 1)" >> "$d/calls"
STUB

cat > "$SBX/infisical" <<'STUB'
#!/usr/bin/env bash
d="${CRON_TEST_DIR:?}"
echo "infisical:$*" >> "$d/calls"
for a in "$@"; do
  case "$a" in
    --command=*) eval "${a#--command=}"; exit $? ;;
  esac
done
STUB

chmod +x "$SBX/adduser" "$SBX/bw_export.sh" "$SBX/supercronic" \
         "$SBX/curl" "$SBX/shoutrrr" "$SBX/infisical"

run_entry() {
  (
    export CRON_TEST_DIR="$SBX"
    export ADDUSER_BIN="$SBX/adduser"
    export PING_LIB="$SP/../root/usr/local/lib/bw-export/ping.sh"
    export NOTIFY_LIB="$SP/../root/usr/local/lib/bw-export/notify.sh"
    export BW_EXPORT_SCRIPT="$SBX/bw_export.sh"
    export SUPERCRONIC_BIN="$SBX/supercronic"
    export CURL_BIN="$SBX/curl"
    export SHOUTRRR_BIN="$SBX/shoutrrr"
    export PATH="$SBX:$PATH"
    export CRONTAB_FILE="$SBX/crontab"
    export LOCK_FILE="$SBX/lock"
    export LOGFILE_DEFAULT="$SBX/default.log"
    export RUN_AS_USER=""
    bash "$ENTRY"
  ) > "$SBX/stdout" 2>&1
  echo $?
}

reset() {
  rm -f "$SBX/calls" "$SBX/stdout" "$SBX/crontab" "$SBX/seen_crontab" \
        "$SBX/lock" "$SBX/default.log" "$SBX/file.log" "$SBX/file.log.1" \
        "$SBX/last_notify"
}

echo "=== C1: without CRON, runs once, overwrites FILE_LOG, never calls supercronic ==="
reset
printf 'old-log-entry\n' > "$SBX/file.log"
rc=$(unset CRON; FILE_LOG="$SBX/file.log" BW_EXPORT_TAG=oneshot run_entry)
eq "exit 0"                "0"   "$rc"
eq "adduser ran once"      "1"   "$(grep -c '^adduser$' "$SBX/calls")"
eq "bw_export ran once"    "1"   "$(grep -c '^bw_export:oneshot$' "$SBX/calls")"
eq "supercronic not run"   "0"   "$(grep -c 'supercronic' "$SBX/calls")"
eq "FILE_LOG overwritten"  "0"   "$(grep -c 'old-log-entry' "$SBX/file.log")"
eq "FILE_LOG has new line" "1"   "$(grep -c 'log-line:oneshot' "$SBX/file.log")"

echo "=== C2: without CRON, failure exit code is preserved ==="
reset
rc=$(unset CRON; BW_EXPORT_RC=1 run_entry)
eq "exit 1" "1" "$rc"

echo "=== C3: with CRON, validates schedule, runs initial backup, appends FILE_LOG, starts supercronic ==="
reset
printf 'previous-log\n' > "$SBX/file.log"
rc=$(CRON="0 3 * * *" FILE_LOG="$SBX/file.log" BW_EXPORT_TAG=startup run_entry)
eq "exit 0"                     "0" "$rc"
eq "adduser ran only once"      "1" "$(grep -c '^adduser$' "$SBX/calls")"
eq "crontab validated first"    "1" "$(grep -c '^supercronic -test ' "$SBX/calls")"
eq "startup backup ran"         "1" "$(grep -c '^bw_export:startup$' "$SBX/calls")"
eq "scheduled backup ran"       "1" "$(grep -c '^bw_export:scheduled$' "$SBX/calls")"
eq "supercronic started"        "1" "$(grep -c "^supercronic $SBX/crontab$" "$SBX/calls")"
eq "crontab has --run-once"     "1" "$(grep -c '^0 3 \* \* \* .* --run-once$' "$SBX/seen_crontab")"
eq "FILE_LOG kept previous"     "1" "$(grep -c 'previous-log' "$SBX/file.log")"
eq "FILE_LOG appended startup"  "1" "$(grep -c 'log-line:startup' "$SBX/file.log")"
eq "FILE_LOG appended tick"     "1" "$(grep -c 'log-line:scheduled' "$SBX/file.log")"

echo "=== C4: invalid CRON fails fast before running any backup ==="
reset
rc=$(CRON="not-a-cron" SUPERCRONIC_BAD=1 run_entry)
eq "exit 1"                "1" "$rc"
eq "no backup attempted"   "0" "$(grep -c '^bw_export:' "$SBX/calls")"
eq "error message printed" "1" "$(grep -c 'ERROR: Invalid CRON expression' "$SBX/stdout")"

echo "=== C5: startup backup failing in CRON mode still starts supercronic ==="
reset
rc=$(CRON="0 3 * * *" BW_EXPORT_RC=1 BW_EXPORT_TAG=startup run_entry)
eq "supercronic still started" "1" "$(grep -c "^supercronic $SBX/crontab$" "$SBX/calls")"
eq "startup ran"               "1" "$(grep -c '^bw_export:startup$' "$SBX/calls")"

echo "=== C6: empty CRON='' behaves identically to unset CRON (one-shot) ==="
reset
printf 'stale-line\n' > "$SBX/file.log"
rc=$(CRON="" FILE_LOG="$SBX/file.log" BW_EXPORT_TAG=empty run_entry)
eq "exit 0"                "0" "$rc"
eq "supercronic not run"   "0" "$(grep -c 'supercronic' "$SBX/calls")"
eq "FILE_LOG overwritten"  "0" "$(grep -c 'stale-line' "$SBX/file.log")"
eq "FILE_LOG has new line" "1" "$(grep -c 'log-line:empty' "$SBX/file.log")"

echo "=== C7: one-shot mode preserves PING_URL and NOTIFICATION_URL lifecycle ==="
reset
rc=$(unset CRON; PING_URL="https://hc.example/{code}" NOTIFICATION_URL="telegram://tok@telegram?chats=1" run_entry)
eq "exit 0"              "0" "$rc"
eq "ping start sent"     "1" "$(grep -c '^ping:https://hc.example/start$' "$SBX/calls")"
eq "ping 0 sent"         "1" "$(grep -c '^ping:https://hc.example/0$' "$SBX/calls")"
eq "notify started"      "1" "$(grep -c '^notify:Bitwarden/Vaultwarden Export: Started$' "$SBX/calls")"
eq "notify completed"    "1" "$(grep -c '^notify:Bitwarden/Vaultwarden Export: Successfully completed' "$SBX/calls")"

echo "=== C8: flock prevents overlapping scheduled runs ==="
reset
rc=$(CRON="0 3 * * *" SUPERCRONIC_HOLD_LOCK=1 BW_EXPORT_TAG=startup run_entry)
eq "exit 0"                       "0" "$rc"
eq "startup ran (not locked)"     "1" "$(grep -c '^bw_export:startup$' "$SBX/calls")"
eq "scheduled skipped (locked)"   "0" "$(grep -c '^bw_export:scheduled$' "$SBX/calls")"
eq "skip message logged"          "1" "$(grep -c 'skipping this scheduled run' "$SBX/stdout")"

echo "=== C9: macro CRON (@daily) works ==="
reset
rc=$(CRON="@daily" BW_EXPORT_TAG=startup run_entry)
eq "exit 0"             "0" "$rc"
eq "macro in crontab"   "1" "$(grep -c '^@daily .* --run-once$' "$SBX/seen_crontab")"
eq "scheduled ran"      "1" "$(grep -c '^bw_export:scheduled$' "$SBX/calls")"

echo "=== C10: FILE_LOG rotates at limit; default log without FILE_LOG stays overwritten ==="
reset
printf '01234567890123456789012345678901234567890123456789\n' > "$SBX/file.log"
rc=$(CRON="0 3 * * *" FILE_LOG="$SBX/file.log" FILE_LOG_MAX_BYTES=20 BW_EXPORT_TAG=startup run_entry)
eq "exit 0"               "0" "$rc"
eq "rotated .1 created"   "1" "$([ -f "$SBX/file.log.1" ] && echo 1 || echo 0)"
eq "new log has startup"  "1" "$(grep -c 'log-line:startup' "$SBX/file.log")"

reset
printf 'old-default\n' > "$SBX/default.log"
rc=$(CRON="0 3 * * *" BW_EXPORT_TAG=startup run_entry)
eq "default log not appended" "0" "$(grep -c 'old-default' "$SBX/default.log")"

echo "=== C11: per-run failure notifications in CRON mode do not leak previous run lines ==="
reset
rc=$(CRON="0 3 * * *" FILE_LOG="$SBX/file.log" \
     PING_URL="https://hc.example/{code}" NOTIFICATION_URL="telegram://tok@telegram?chats=1" \
     BW_EXPORT_TAG=startup BW_EXPORT_FAIL_ON_TAG=scheduled run_entry)
eq "ping start sent twice"     "2" "$(grep -c '^ping:https://hc.example/start$' "$SBX/calls")"
eq "ping 0 sent once"          "1" "$(grep -c '^ping:https://hc.example/0$' "$SBX/calls")"
eq "ping 1 sent once"          "1" "$(grep -c '^ping:https://hc.example/1$' "$SBX/calls")"
eq "notify has current error"  "1" "$(grep -c 'current-run-error-only' "$SBX/last_notify")"
eq "notify omits startup line" "0" "$(grep -c 'log-line:startup' "$SBX/last_notify")"

echo "=== C12: INFISICAL_TOKEN works in both startup and scheduled CRON runs ==="
reset
rc=$(CRON="0 3 * * *" INFISICAL_TOKEN=tok INFISICAL_PATH=/prod BW_EXPORT_TAG=startup run_entry)
eq "exit 0"              "0" "$rc"
eq "startup ran"         "1" "$(grep -c '^bw_export:startup$' "$SBX/calls")"
eq "scheduled ran"       "1" "$(grep -c '^bw_export:scheduled$' "$SBX/calls")"
eq "infisical ran"       "1" "$([ "$(grep -c '^infisical:' "$SBX/calls")" -ge 4 ] && echo 1 || echo 0)"

echo "=== C13: SIGTERM during CRON initial backup forwards signal and skips supercronic ==="
reset
(
  export CRON_TEST_DIR="$SBX" ADDUSER_BIN="$SBX/adduser"
  export PING_LIB="$SP/../root/usr/local/lib/bw-export/ping.sh"
  export NOTIFY_LIB="$SP/../root/usr/local/lib/bw-export/notify.sh"
  export BW_EXPORT_SCRIPT="$SBX/bw_export.sh" SUPERCRONIC_BIN="$SBX/supercronic"
  export CURL_BIN="$SBX/curl" SHOUTRRR_BIN="$SBX/shoutrrr" PATH="$SBX:$PATH"
  export CRONTAB_FILE="$SBX/crontab" LOCK_FILE="$SBX/lock" LOGFILE_DEFAULT="$SBX/default.log"
  export RUN_AS_USER="" CRON="0 3 * * *" BW_EXPORT_SLEEP=10 BW_EXPORT_TAG=startup
  unset INFISICAL_TOKEN
  exec bash "$ENTRY"
) > "$SBX/stdout" 2>&1 &
epid=$!
for _ in $(seq 1 40); do
  grep -q '^bw_export:startup$' "$SBX/calls" 2>/dev/null && break
  sleep 0.1
done
kill -TERM "$epid"
wait "$epid" 2>/dev/null
rc=$?
eq "exit 143 on SIGTERM"      "143" "$rc"
eq "bw_export got SIGTERM"    "1"   "$(grep -c '^bw_export:got_term$' "$SBX/calls")"
eq "supercronic never started" "0"  "$(grep -c "^supercronic $SBX/crontab$" "$SBX/calls")"

echo ""
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
