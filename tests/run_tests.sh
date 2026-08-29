#!/usr/bin/env bash
# Test harness for bw_export.sh against the stateful bw mock.
SP="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:?}"
pass=0; fail=0

# Sets up a fresh sandbox; $1 = a snippet that seeds the CLI state file.
setup() {
  unset PW BW_FAIL_CONFIG BW_FAIL_LOGIN BW_FAIL_LOGOUT BITWARDENCLI_APPDATA_DIR \
        BW_ITEMS_FILE BW_ATTACHLOG BW_FAIL_ATTACH KEEP_LAST_BACKUPS
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
echo "=== T15: a vault with items but no attachments must say so ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
# The CLI reports an empty array, not null, for an item without attachments.
printf '%s' '[{"id":"i1","name":"Plain","attachments":[]},{"id":"i2","name":"Other","attachments":[]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "reports nothing to export" "$(grep -q 'No attachments exist' "$SP/sbx/output"; echo $?)" "$(tail -3 "$SP/sbx/output")"
check "does NOT claim to be saving" "$(! grep -q 'Saving attachments' "$SP/sbx/output"; echo $?)" "claimed to save nothing"
check "no attachment downloaded" "$([ ! -s "$SP/sbx/attach" ]; echo $?)" "$(cat "$SP/sbx/attach" 2>/dev/null)"
check "lists items only once" "$([ "$(grep -c '^bw list items$' "$SP/sbx/calls")" = 1 ]; echo $?)" "count=$(grep -c '^bw list items$' "$SP/sbx/calls")"

echo "=== T16: an item that does have an attachment is downloaded ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
printf '%s' '[{"id":"i1","name":"Plain","attachments":[]},{"id":"i2","name":"Doc","attachments":[{"fileName":"cv.pdf"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "announces saving" "$(grep -q 'Saving attachments' "$SP/sbx/output"; echo $?)" "no message"
check "downloaded exactly one" "$([ "$(grep -c '^ATTACHMENT' "$SP/sbx/attach")" = 1 ]; echo $?)" "$(cat "$SP/sbx/attach")"
check "correct itemid and file" "$(grep -qP '^ATTACHMENT\ti2\tcv\.pdf\t' "$SP/sbx/attach"; echo $?)" "$(cat "$SP/sbx/attach")"
check "file written under the item name" "$(compgen -G "$SP/sbx/att/*/Doc/cv.pdf" >/dev/null; echo $?)" "$(find "$SP/sbx/att" -type f)"

echo "=== T17: a hostile item name must not reach the shell (command injection) ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
rm -f "$SP/sbx/PWNED"
# $(...) and backticks in a name; the old code built shell text and ran it.
printf '%s' '[{"id":"i1","name":"INJ$(touch '"$SP"'/sbx/PWNED)END","attachments":[{"fileName":"a.txt"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "payload did NOT execute" "$([ ! -e "$SP/sbx/PWNED" ]; echo $?)" "the name was evaluated as shell"
check "name passed through verbatim" "$(grep -qF 'INJ$(touch' "$SP/sbx/attach"; echo $?)" "$(cat "$SP/sbx/attach")"

echo "=== T18: a hostile attachment file name must not reach the shell either ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
rm -f "$SP/sbx/PWNED2"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"x$(touch '"$SP"'/sbx/PWNED2)y"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "payload did NOT execute" "$([ ! -e "$SP/sbx/PWNED2" ]; echo $?)" "the file name was evaluated as shell"
check "file name passed through verbatim" "$(grep -qF 'x$(touch' "$SP/sbx/attach"; echo $?)" "$(cat "$SP/sbx/attach")"

echo "=== T19: the item name becomes a directory every filesystem accepts ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
# "/" and "\" are separators; NTFS also rejects < > : " | ? * and trailing dots.
printf '%s' '[{"id":"i1","name":"He said \"hi\"","attachments":[{"fileName":"q.txt"}]},
              {"id":"i2","name":"Foo/Bar","attachments":[{"fileName":"s.txt"}]},
              {"id":"i3","name":"a<b>c:d|e?f*g","attachments":[{"fileName":"m.txt"}]},
              {"id":"i4","name":"back\\slash","attachments":[{"fileName":"b.txt"}]},
              {"id":"i5","name":"trailing. ","attachments":[{"fileName":"t.txt"}]},
              {"id":"i6","name":"...","attachments":[{"fileName":"u.txt"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "quotes replaced"          "$(compgen -G "$SP/sbx/att/*/He said _hi_/q.txt" >/dev/null; echo $?)" "$(find "$SP/sbx/att" -type d)"
check "slash does not nest"      "$(compgen -G "$SP/sbx/att/*/Foo_Bar/s.txt" >/dev/null; echo $?)"      "$(find "$SP/sbx/att" -type d)"
check "NTFS-illegal replaced"    "$(compgen -G "$SP/sbx/att/*/a_b_c_d_e_f_g/m.txt" >/dev/null; echo $?)" "$(find "$SP/sbx/att" -type d)"
check "backslash does not nest"  "$(compgen -G "$SP/sbx/att/*/back_slash/b.txt" >/dev/null; echo $?)"   "$(find "$SP/sbx/att" -type d)"
check "trailing dot/space gone"  "$(compgen -G "$SP/sbx/att/*/trailing/t.txt" >/dev/null; echo $?)"     "$(find "$SP/sbx/att" -type d)"
check "empty name falls back"    "$(compgen -G "$SP/sbx/att/*/unnamed/u.txt" >/dev/null; echo $?)"      "$(find "$SP/sbx/att" -type d)"
check "all six downloaded" "$([ "$(grep -c '^ATTACHMENT' "$SP/sbx/attach")" = 6 ]; echo $?)" "$(cat "$SP/sbx/attach")"
check "no directory nesting at all" "$([ "$(find "$SP/sbx/att" -mindepth 3 -type d | wc -l)" = 0 ]; echo $?)" "$(find "$SP/sbx/att" -mindepth 3 -type d)"
unset BW_ITEMS_FILE BW_ATTACHLOG

echo "=== T20: an attachment that fails to download must not pass as a good backup ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
printf '%s' '[{"id":"i1","name":"Ok","attachments":[{"fileName":"good.txt"}]},
              {"id":"i2","name":"Broken","attachments":[{"fileName":"bad.txt"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json" BW_FAIL_ATTACH=bad.txt
rc=$(run)
check "exit 1 (incomplete backup)" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "counts the failure" "$(grep -q '1 attachment(s) could not be saved' "$SP/sbx/output"; echo $?)" "$(tail -4 "$SP/sbx/output")"
check "says the backup is incomplete" "$(grep -q 'This backup is incomplete' "$SP/sbx/output"; echo $?)" "no final warning"
check "no 'Have a good day'" "$(! grep -q 'Have a good day' "$SP/sbx/output"; echo $?)" "reported success anyway"
check "the good one was still saved" "$(compgen -G "$SP/sbx/att/*/Ok/good.txt" >/dev/null; echo $?)" "$(find "$SP/sbx/att" -type f)"
check "session still closed" "$(state_is_clean; echo $?)" "$(cat "$BW_STATE")"

echo "=== T21: every attachment failing is still counted, not just the first ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
printf '%s' '[{"id":"i1","name":"A","attachments":[{"fileName":"bad.txt"}]},
              {"id":"i2","name":"B","attachments":[{"fileName":"bad.txt"}]},
              {"id":"i3","name":"C","attachments":[{"fileName":"bad.txt"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json" BW_FAIL_ATTACH=bad.txt
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "counts all three" "$(grep -q '3 attachment(s) could not be saved' "$SP/sbx/output"; echo $?)" "$(grep -o '[0-9]* attachment(s) could not be saved' "$SP/sbx/output")"
check "all three were attempted" "$([ "$(grep -c '^ATTACHMENT' "$SP/sbx/attach")" = 3 ]; echo $?)" "$(cat "$SP/sbx/attach")"

echo "=== T22: attachments all succeeding must still exit 0 ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
printf '%s' '[{"id":"i1","name":"A","attachments":[{"fileName":"a.txt"}]},
              {"id":"i2","name":"B","attachments":[{"fileName":"b.txt"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "reports success" "$(grep -q 'Have a good day' "$SP/sbx/output"; echo $?)" "no success message"
check "no spurious failure count" "$(! grep -q 'could not be saved' "$SP/sbx/output"; echo $?)" "claimed a failure"
unset BW_ITEMS_FILE BW_ATTACHLOG BW_FAIL_ATTACH

echo "=== T23: an incomplete export must not rotate a complete backup out ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
mkdir -p "$SP/sbx/out/20200101000000-bw-export" "$SP/sbx/out/20200102000000-bw-export" \
         "$SP/sbx/att/20200101000000-bw-export" "$SP/sbx/att/20200102000000-bw-export"
printf '%s' '[{"id":"i1","name":"Broken","attachments":[{"fileName":"bad.txt"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json" BW_FAIL_ATTACH=bad.txt KEEP_LAST_BACKUPS=1
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says it is keeping them" "$(grep -q 'keeping all previous backups' "$SP/sbx/output"; echo $?)" "$(tail -5 "$SP/sbx/output")"
check "old vault backups untouched" "$([ -d "$SP/sbx/out/20200101000000-bw-export" ] && [ -d "$SP/sbx/out/20200102000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "old attachment backups untouched" "$([ -d "$SP/sbx/att/20200101000000-bw-export" ] && [ -d "$SP/sbx/att/20200102000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/att")"
check "did not run the cleanup" "$(! grep -q 'Starting cleaning previous backups' "$SP/sbx/output"; echo $?)" "pruned anyway"

echo "=== T24: a complete export still rotates as configured ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
mkdir -p "$SP/sbx/out/20200101000000-bw-export" "$SP/sbx/out/20200102000000-bw-export"
printf '%s' '[{"id":"i1","name":"Ok","attachments":[{"fileName":"good.txt"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json" KEEP_LAST_BACKUPS=1
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "ran the cleanup" "$(grep -q 'Starting cleaning previous backups' "$SP/sbx/output"; echo $?)" "skipped it"
check "oldest was deleted" "$([ ! -d "$SP/sbx/out/20200101000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "only KEEP_LAST_BACKUPS remain" "$([ "$(find "$SP/sbx/out" -maxdepth 1 -name '*-bw-export' -type d | wc -l)" = 1 ]; echo $?)" "$(ls "$SP/sbx/out")"
unset BW_ITEMS_FILE BW_ATTACHLOG BW_FAIL_ATTACH KEEP_LAST_BACKUPS

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
