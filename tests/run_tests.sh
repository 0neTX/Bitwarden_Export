#!/usr/bin/env bash
# Test harness for bw_export.sh against the stateful bw mock.
SP="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:?}"
pass=0; fail=0

# Sets up a fresh sandbox; $1 = a snippet that seeds the CLI state file.
setup() {
  unset PW BW_FAIL_CONFIG BW_FAIL_LOGIN BW_FAIL_LOGOUT BITWARDENCLI_APPDATA_DIR
  rm -rf "$SP/sbx"; mkdir -p "$SP/sbx/out" "$SP/sbx/att"
  export BW_STATE="$SP/sbx/state" BW_CALLLOG="$SP/sbx/calls"
  : > "$BW_CALLLOG"
  [ -n "$1" ] && printf '%s\n' "$1" > "$BW_STATE"
}

run() {
  ( export PATH="$SP/mock:$PATH" \
      OUTPUT_PATH="$SP/sbx/out" ATTACHMENTS_PATH="$SP/sbx/att" \
      BW_URL_SERVER="https://vw.example.com" \
      BW_CLIENTID=id BW_CLIENTSECRET=secret BW_PASSWORD="${PW:-correct-pw}" \
      EXPORT_PASSWORD=exp
    bash "$SCRIPT" ) > "$SP/sbx/output" 2>&1
  echo $?
}

check() { # name, condition-result(0/1), detail
  if [ "$2" = 0 ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  -- $3"; fail=$((fail+1)); fi
}
state_is_clean() { grep -q '^auth=0' "$BW_STATE"; }
exported()       { [ -f "$SP/sbx/out"/*/export.json ] 2>/dev/null || compgen -G "$SP/sbx/out/*/export.json" >/dev/null; }

echo "=== T1: cold start (no cached state) ==="
setup ""
export BW_REAL_PW=correct-pw
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "export written" "$(exported; echo $?)" "no export file"
check "session closed at end" "$(state_is_clean; echo $?)" "$(cat "$BW_STATE")"
check "logged out exactly once" "$([ "$(grep -c '^bw logout' "$SP/sbx/calls")" = 1 ]; echo $?)" "count=$(grep -c '^bw logout' "$SP/sbx/calls")"

echo "=== T2: issue #21 -- stale LOCKED session with stale cached password ==="
setup 'auth=1
locked=1
cached_pw=old-pw-from-before-the-server-upgrade
server=https://vw.example.com'
export BW_REAL_PW=correct-pw
rc=$(run)
check "recovers, exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"
check "detected stale session" "$(grep -q 'Existing session detected' "$SP/sbx/output"; echo $?)" "not detected"
check "no 'Logout required' error" "$(! grep -q 'Logout required' "$SP/sbx/output"; echo $?)" "config still rejected"
check "export written" "$(exported; echo $?)" "no export file"

echo "=== T3: stale UNLOCKED session (previous run died after unlock) ==="
setup 'auth=1
locked=0
cached_pw=old-pw
server=https://vw.example.com'
export BW_REAL_PW=correct-pw
rc=$(run)
check "recovers, exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"

echo "=== T4: genuinely wrong BW_PASSWORD ==="
setup ""
export BW_REAL_PW=the-real-one
rc=$(PW=definitely-wrong; run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "reports unlock error" "$(grep -q 'Failed to unlock vault' "$SP/sbx/output"; echo $?)" "no error message"
check "state left CLEAN (no trap poisoning)" "$(state_is_clean; echo $?)" "$(cat "$BW_STATE")"

echo "=== T5: run immediately after T4's failure must still work ==="
export BW_REAL_PW=the-real-one
rc=$(PW=the-real-one; run)
check "exit 0 (failure is not sticky)" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"

echo "=== T6: 'bw config server' fails ==="
setup ""
export BW_REAL_PW=correct-pw BW_FAIL_CONFIG=1
rc=$(run)
check "exit 1 (no longer silently ignored)" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "reports server error" "$(grep -q 'Failed to set the server url' "$SP/sbx/output"; echo $?)" "no message"
check "no export attempted" "$(! exported; echo $?)" "exported despite config failure"
unset BW_FAIL_CONFIG

echo "=== T7: login fails ==="
setup ""
export BW_REAL_PW=correct-pw BW_FAIL_LOGIN=1
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "reports login error" "$(grep -q 'Failed to login' "$SP/sbx/output"; echo $?)" "no message"
unset BW_FAIL_LOGIN

echo "=== T8: no BW_URL_SERVER (bitwarden.com path) ==="
setup ""
export BW_REAL_PW=correct-pw
rc=$( export PATH="$SP/mock:$PATH" OUTPUT_PATH="$SP/sbx/out" ATTACHMENTS_PATH="$SP/sbx/att" \
        BW_CLIENTID=id BW_CLIENTSECRET=secret BW_PASSWORD=correct-pw EXPORT_PASSWORD=exp
      bash "$SCRIPT" > "$SP/sbx/output" 2>&1; echo $? )
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"
check "skips server config" "$(! grep -q 'Setting custom server' "$SP/sbx/output"; echo $?)" "configured anyway"

echo "=== T9: missing required env var still exits before touching the CLI ==="
setup ""
rc=$( export PATH="$SP/mock:$PATH" OUTPUT_PATH="$SP/sbx/out" ATTACHMENTS_PATH="$SP/sbx/att" \
        BW_CLIENTSECRET=secret BW_PASSWORD=pw
      bash "$SCRIPT" > "$SP/sbx/output" 2>&1; echo $? )
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "no bw calls made" "$([ ! -s "$SP/sbx/calls" ]; echo $?)" "calls: $(cat "$SP/sbx/calls")"
check "no spurious 'Closing session'" "$(! grep -q 'Closing Bitwarden CLI session' "$SP/sbx/output"; echo $?)" "trap fired too early"

echo "=== T10: stale cache, TWO consecutive runs (the reported 'stopped working for good') ==="
setup 'auth=1
locked=1
cached_pw=stale-pw
server=https://vw.example.com'
export BW_REAL_PW=correct-pw
rc1=$(run); rc2=$(run)
check "run 1 succeeds" "$([ "$rc1" = 0 ]; echo $?)" "rc=$rc1"
check "run 2 succeeds (not sticky)" "$([ "$rc2" = 0 ]; echo $?)" "rc=$rc2"

echo "=== T11: container stopped mid-run (SIGTERM) must not leave a session ==="
setup ""
export BW_REAL_PW=correct-pw
( export PATH="$SP/mock:$PATH" OUTPUT_PATH="$SP/sbx/out" ATTACHMENTS_PATH="$SP/sbx/att" \
    BW_URL_SERVER="https://vw.example.com" BW_CLIENTID=id BW_CLIENTSECRET=secret \
    BW_PASSWORD=correct-pw EXPORT_PASSWORD=exp BW_SLOW_EXPORT=1
  bash "$SCRIPT" ) > "$SP/sbx/output" 2>&1 &
sigpid=$!
# wait until the vault is unlocked (state written), then stop the "container"
for _ in $(seq 1 200); do grep -q '^locked=0' "$BW_STATE" 2>/dev/null && break; sleep 0.05; done
kill -TERM "$sigpid" 2>/dev/null; wait "$sigpid" 2>/dev/null
check "was actually unlocked before SIGTERM" "$(grep -q 'Vault unlocked' "$SP/sbx/output"; echo $?)" "never reached unlock"
check "session closed after SIGTERM" "$(state_is_clean; echo $?)" "$(cat "$BW_STATE")"

echo
echo "=== T12: pre-emptive logout itself fails -> must fail loudly, not confusingly ==="
setup 'auth=1
locked=1
cached_pw=stale-pw
server=https://vw.example.com'
export BW_REAL_PW=correct-pw BW_FAIL_LOGOUT=1
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "names the real cause" "$(grep -q 'Could not log out the previous session' "$SP/sbx/output"; echo $?)" "$(tail -3 "$SP/sbx/output")"
check "does NOT blame BW_PASSWORD" "$(! grep -q 'Failed to unlock vault' "$SP/sbx/output"; echo $?)" "misleading error"
unset BW_FAIL_LOGOUT

echo
echo "=== T13: BITWARDENCLI_APPDATA_DIR default must actually reach the bw process ==="
setup ""
export BW_REAL_PW=correct-pw
rc=$( cd "$SP/sbx" && export PATH="$SP/mock:$PATH" OUTPUT_PATH="$SP/sbx/out" ATTACHMENTS_PATH="$SP/sbx/att" \
        BW_URL_SERVER="https://vw.example.com" BW_CLIENTID=id BW_CLIENTSECRET=secret \
        BW_PASSWORD=correct-pw EXPORT_PASSWORD=exp
      bash "$SCRIPT" > "$SP/sbx/output" 2>&1; echo $? )
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "bw receives it (not <UNSET>)" "$(! grep -q 'APPDATA=\[<UNSET>\]' "$SP/sbx/calls"; echo $?)" "bw never saw the variable"
check "defaults to the working dir" "$(grep -q "APPDATA=\[$SP/sbx\]" "$SP/sbx/calls"; echo $?)" "got: $(grep -m1 APPDATA "$SP/sbx/calls")"

echo "=== T14: an explicit BITWARDENCLI_APPDATA_DIR still overrides the default ==="
setup ""
export BW_REAL_PW=correct-pw
rc=$( cd "$SP/sbx" && export PATH="$SP/mock:$PATH" OUTPUT_PATH="$SP/sbx/out" ATTACHMENTS_PATH="$SP/sbx/att" \
        BW_URL_SERVER="https://vw.example.com" BW_CLIENTID=id BW_CLIENTSECRET=secret \
        BW_PASSWORD=correct-pw EXPORT_PASSWORD=exp BITWARDENCLI_APPDATA_DIR=/custom/state
      bash "$SCRIPT" > "$SP/sbx/output" 2>&1; echo $? )
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "override respected" "$(grep -q 'APPDATA=\[/custom/state\]' "$SP/sbx/calls"; echo $?)" "got: $(grep -m1 APPDATA "$SP/sbx/calls")"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
