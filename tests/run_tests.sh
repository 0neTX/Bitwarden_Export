#!/usr/bin/env bash
# Test harness for bw_export.sh against the stateful bw mock.
#
# Assertions read as `check "name" "$([ cond ]; echo $?)" "detail"`, where $? is
# meant to be the condition's status. That is what SC2319 warns about, so it is
# silenced here rather than at ~80 call sites. Each run() is deliberately a
# subshell so its environment cannot leak into the next test, which is what
# SC2030/SC2031 flag. The injection tests carry payloads that must stay literal,
# so SC2016 ("expressions don't expand in single quotes") is the point of them.
# shellcheck disable=SC2319,SC2030,SC2031,SC2016
SP="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:?}"
pass=0; fail=0

# Sets up a fresh sandbox; $1 = a snippet that seeds the CLI state file.
setup() {
  unset PW BW_FAIL_CONFIG BW_FAIL_LOGIN BW_FAIL_LOGOUT BITWARDENCLI_APPDATA_DIR \
        BW_ITEMS_FILE BW_ATTACHLOG BW_FAIL_ATTACH KEEP_LAST_BACKUPS \
        BW_FAIL_EXPORT BW_ORGANIZATIONS_LIST BW_FAIL_LIST EXP BW_EXPORT_NOFILE \
        BW_ORGS_JSON BW_DENY_EXPORT
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
      EXPORT_PASSWORD="${EXP-exp}" BW_EXPORT_PWLOG="$SP/sbx/pwlog"
    bash "$SCRIPT" ) > "$SP/sbx/output" 2>&1
  echo $?
}

check() { # name, condition-result(0/1), detail
  if [ "$2" = 0 ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  -- $3"; fail=$((fail+1)); fi
}
state_is_clean() { grep -q '^auth=0' "$BW_STATE"; }
exported()       { compgen -G "$SP/sbx/out/*/export-personal.json" >/dev/null; }

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

echo "=== T25: a personal vault export that fails must not pass as a good backup ==="
setup ""
export BW_REAL_PW=correct-pw BW_FAIL_EXPORT=personal BW_ORGANIZATIONS_LIST=o1
rc=$(run)
check "exit 1 (incomplete backup)" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "names the failed export" "$(grep -q 'ERROR: Failed to export the personal vault' "$SP/sbx/output"; echo $?)" "$(tail -6 "$SP/sbx/output")"
check "counts it" "$(grep -q 'but 1 vault export(s) failed' "$SP/sbx/output"; echo $?)" "$(tail -4 "$SP/sbx/output")"
check "says the backup is incomplete" "$(grep -q 'This backup is incomplete' "$SP/sbx/output"; echo $?)" "no final warning"
check "no 'Vault export complete'" "$(! grep -q 'Vault export complete' "$SP/sbx/output"; echo $?)" "claimed completion"
check "no 'Have a good day'" "$(! grep -q 'Have a good day' "$SP/sbx/output"; echo $?)" "reported success anyway"
check "the organization was still exported" "$(compgen -G "$SP/sbx/out/*/export-o1.json" >/dev/null; echo $?)" "$(find "$SP/sbx/out" -type f)"
check "session still closed" "$(state_is_clean; echo $?)" "$(cat "$BW_STATE")"

echo "=== T26: one organization failing is counted, the others still exported ==="
setup ""
export BW_REAL_PW=correct-pw BW_FAIL_EXPORT=o2 BW_ORGANIZATIONS_LIST=o1,o2,o3
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "names the organization" "$(grep -q 'Failed to export the organization vault o2' "$SP/sbx/output"; echo $?)" "$(grep ERROR "$SP/sbx/output")"
check "counts exactly one" "$(grep -q 'but 1 vault export(s) failed' "$SP/sbx/output"; echo $?)" "$(grep -o '[0-9]* vault export(s) failed' "$SP/sbx/output")"
check "all three were attempted" "$([ "$(grep -c '^bw export --organizationid' "$BW_CALLLOG")" = 3 ]; echo $?)" "$(grep '^bw export' "$BW_CALLLOG")"
check "the others were saved" "$(compgen -G "$SP/sbx/out/*/export-o1.json" >/dev/null && compgen -G "$SP/sbx/out/*/export-o3.json" >/dev/null && exported; echo $?)" "$(find "$SP/sbx/out" -type f)"

echo "=== T27: a failed export must not rotate a complete backup out ==="
setup ""
export BW_REAL_PW=correct-pw BW_FAIL_EXPORT=personal KEEP_LAST_BACKUPS=1
mkdir -p "$SP/sbx/out/20200101000000-bw-export" "$SP/sbx/out/20200102000000-bw-export"
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says it is keeping them" "$(grep -q 'keeping all previous backups' "$SP/sbx/output"; echo $?)" "$(tail -5 "$SP/sbx/output")"
check "old backups untouched" "$([ -d "$SP/sbx/out/20200101000000-bw-export" ] && [ -d "$SP/sbx/out/20200102000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "did not run the cleanup" "$(! grep -q 'Starting cleaning previous backups' "$SP/sbx/output"; echo $?)" "pruned anyway"

echo "=== T28: exports with organizations all succeeding must still exit 0 ==="
setup ""
export BW_REAL_PW=correct-pw BW_ORGANIZATIONS_LIST=o1,o2
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "reports completion" "$(grep -q 'Vault export complete' "$SP/sbx/output" && grep -q 'Have a good day' "$SP/sbx/output"; echo $?)" "$(tail -4 "$SP/sbx/output")"
check "no spurious failure" "$(! grep -q 'export(s) failed\|Failed to export' "$SP/sbx/output"; echo $?)" "$(grep -i fail "$SP/sbx/output")"
check "all three files written" "$([ "$(find "$SP/sbx/out" -name 'export-*.json' | wc -l)" = 3 ]; echo $?)" "$(find "$SP/sbx/out" -type f)"
unset BW_FAIL_EXPORT BW_ORGANIZATIONS_LIST KEEP_LAST_BACKUPS

echo "=== T29: an items listing that fails is not 'no attachments' ==="
setup ""
export BW_REAL_PW=correct-pw BW_FAIL_LIST=items
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says it could not list" "$(grep -q 'Could not list the vault items' "$SP/sbx/output"; echo $?)" "$(grep -i 'attach' "$SP/sbx/output")"
check "no 'No attachments exist'" "$(! grep -q 'No attachments exist' "$SP/sbx/output"; echo $?)" "claimed the vault has none"
check "the vault itself was still exported" "$(exported; echo $?)" "$(find "$SP/sbx/out" -type f)"

echo "=== T30: an organizations listing that fails is not 'no organizations' ==="
setup ""
export BW_REAL_PW=correct-pw BW_FAIL_LIST=organizations
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says it could not list" "$(grep -q 'Could not list the organizations' "$SP/sbx/output"; echo $?)" "$(grep -i 'organi' "$SP/sbx/output")"
check "no 'No organizational vault exists'" "$(! grep -q 'No organizational vault exists' "$SP/sbx/output"; echo $?)" "claimed there are none"
check "no 'Have a good day'" "$(! grep -q 'Have a good day' "$SP/sbx/output"; echo $?)" "reported success anyway"
unset BW_FAIL_LIST
echo "=== T31: neither password reaches a command line (ps shows those to every user) ==="
setup ""
# Spaces, quotes, a dollar sign and a backslash: each would break or be expanded
# by a careless hand-off. The mock logs every argv it is given.
export PW=' master "pw" $HOME \x ' BW_REAL_PW=' master "pw" $HOME \x ' \
       EXP=" export 'pw' \$PATH \\y " BW_ORGANIZATIONS_LIST=o1
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"
check "master password in no argv" "$(! grep -qF 'master "pw"' "$SP/sbx/calls"; echo $?)" "$(grep -F 'master "pw"' "$SP/sbx/calls")"
check "export password in no argv" "$(! grep -qF "export 'pw'" "$SP/sbx/calls"; echo $?)" "$(grep -F "export 'pw'" "$SP/sbx/calls")"
check "unlock takes it from the environment" "$(grep -q '^bw unlock --passwordenv ' "$SP/sbx/calls"; echo $?)" "$(grep '^bw unlock' "$SP/sbx/calls")"
check "personal export got the exact password" "$(grep -qxF "personal	$EXP" "$SP/sbx/pwlog"; echo $?)" "pwlog: $(cut -f1 "$SP/sbx/pwlog")"
check "organization export got it too" "$(grep -qxF "o1	$EXP" "$SP/sbx/pwlog"; echo $?)" "pwlog: $(cut -f1 "$SP/sbx/pwlog")"
check "both files written" "$([ "$(find "$SP/sbx/out" -name 'export-*.json' | wc -l)" = 2 ]; echo $?)" "$(find "$SP/sbx/out" -type f)"
check "no password prompt in the log" "$(! grep -q 'Export file password' "$SP/sbx/output"; echo $?)" "prompt redraws leak the length"
check "the internal variable does not outlive unlock" "$(! grep -q 'BW_EXPORT_UNLOCK_PASSWORD=' "$SP/sbx/output"; echo $?)" "leaked"

echo "=== T32: BW_PASSWORD and EXPORT_PASSWORD as files still work ==="
setup ""
printf '%s\n' 'file-master-pw' > "$SP/sbx/bwpw"; printf '%s\n' 'file-export-pw' > "$SP/sbx/exppw"
export PW="$SP/sbx/bwpw" BW_REAL_PW=file-master-pw EXP="$SP/sbx/exppw"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"
check "export got the file's password, not its path" "$(grep -qxF 'personal	file-export-pw' "$SP/sbx/pwlog"; echo $?)" "pwlog: $(cut -f1 "$SP/sbx/pwlog")"
check "neither password in argv" "$(! grep -q 'file-master-pw\|file-export-pw' "$SP/sbx/calls"; echo $?)" "$(grep 'file-' "$SP/sbx/calls")"

echo "=== T33: an export the CLI reports as fine but never wrote is a failure ==="
setup ""
# What the real CLI does when the password prompt reads nothing: exit 0, no file.
export BW_REAL_PW=correct-pw BW_EXPORT_NOFILE=personal BW_ORGANIZATIONS_LIST=o1
rc=$(run)
check "exit 1 (incomplete backup)" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says no file was saved" "$(grep -q 'ERROR: The CLI reported no saved file for the personal vault' "$SP/sbx/output"; echo $?)" "$(tail -6 "$SP/sbx/output")"
check "counts it" "$(grep -q 'but 1 vault export(s) failed' "$SP/sbx/output"; echo $?)" "$(tail -4 "$SP/sbx/output")"
check "the organization was still exported" "$(compgen -G "$SP/sbx/out/*/export-o1.json" >/dev/null; echo $?)" "$(find "$SP/sbx/out" -type f)"

echo "=== T34: without EXPORT_PASSWORD the export is unencrypted and prompts for nothing ==="
setup ""
export BW_REAL_PW=correct-pw EXP=""
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"
check "plain json export" "$(grep -q '^bw export --format json --output ' "$SP/sbx/calls"; echo $?)" "$(grep '^bw export' "$SP/sbx/calls")"
check "no --password flag" "$(! grep -q '^bw export.*--password' "$SP/sbx/calls"; echo $?)" "$(grep '^bw export' "$SP/sbx/calls")"
check "export written" "$(exported; echo $?)" "no export file"

echo "=== T35: a detected organization the account cannot export is skipped, not failed ==="
# The reported case: a plain member (User) of someone else's organization. The
# server answers its export with a 401 and the CLI then logs itself out.
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach" \
       BW_ORGS_JSON='[{"id":"o-fam","name":"Familia","status":2,"type":2}]' BW_DENY_EXPORT=o-fam
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(grep -i 'error\|organi' "$SP/sbx/output")"
check "not attempted" "$(! grep -q '^bw export --organizationid' "$BW_CALLLOG"; echo $?)" "$(grep '^bw export' "$BW_CALLLOG")"
check "says why, by name" "$(grep -q 'Skipping organization "Familia" (o-fam): your role (User) cannot export it' "$SP/sbx/output"; echo $?)" "$(grep -i 'organi' "$SP/sbx/output")"
check "not 'No organizational vault exists'" "$(! grep -q 'No organizational vault exists' "$SP/sbx/output"; echo $?)" "claimed there are none"
check "attachments saved" "$(compgen -G "$SP/sbx/att/*/Doc/a.pdf" >/dev/null; echo $?)" "$(find "$SP/sbx/att" -type f)"
check "personal vault saved" "$(exported; echo $?)" "no export file"

echo "=== T36: only a confirmed Owner or Admin has a detected organization exported ==="
setup ""
# Vaultwarden reports its managers as Custom, and the CLI does not show a custom
# role's permissions, so Custom is skipped too. The last name carries an escape
# character and a literal \n: neither may reach the log as such.
export BW_REAL_PW=correct-pw BW_ORGS_JSON='[
  {"id":"o0","name":"Own","status":2,"type":0}, {"id":"o1","name":"Adm","status":2,"type":1},
  {"id":"o2","name":"Usr","status":2,"type":2}, {"id":"o3","name":"Mgr","status":2,"type":3},
  {"id":"o4","name":"Cus","status":2,"type":4}, {"id":"o5","name":"Acc","status":1,"type":0},
  {"id":"o6","name":"Rev\u001b[31m\\n","status":-1,"type":1}]'
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "Owner and Admin exported" "$([ "$(grep -c '^bw export --organizationid' "$BW_CALLLOG")" = 2 ] && grep -q '^bw export --organizationid o0 ' "$BW_CALLLOG" && grep -q '^bw export --organizationid o1 ' "$BW_CALLLOG"; echo $?)" "$(grep '^bw export --org' "$BW_CALLLOG")"
check "five skipped" "$([ "$(grep -c 'Skipping organization' "$SP/sbx/output")" = 5 ]; echo $?)" "$(grep 'Skipping' "$SP/sbx/output")"
check "Manager named" "$(grep -q '(o3): your role (Manager) cannot export it' "$SP/sbx/output"; echo $?)" "$(grep 'o3' "$SP/sbx/output")"
check "Custom named, with the way out" "$(grep -q '(o4): the CLI cannot tell whether your role (Custom) may export it' "$SP/sbx/output" && grep -A1 '(o4)' "$SP/sbx/output" | grep -q 'add its ID to BW_ORGANIZATIONS_LIST'; echo $?)" "$(grep -A1 'o4' "$SP/sbx/output")"
check "unconfirmed named" "$(grep -q '(o5): your membership is not confirmed' "$SP/sbx/output"; echo $?)" "$(grep 'o5' "$SP/sbx/output")"
check "revoked named" "$(grep -q '(o6): your access to it is revoked' "$SP/sbx/output"; echo $?)" "$(grep 'o6' "$SP/sbx/output")"
check "a name cannot write escapes into the log" "$(grep -qF '"Rev_[31m\n" (o6)' "$SP/sbx/output" && ! grep -q $'\e\\[31m' "$SP/sbx/output"; echo $?)" "$(grep 'o6' "$SP/sbx/output" | od -c | head -3)"

echo "=== T37: an organization named in BW_ORGANIZATIONS_LIST is tried, and a refusal explained ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach" BW_ORGANIZATIONS_LIST=o-fam KEEP_LAST_BACKUPS=1 \
       BW_ORGS_JSON='[{"id":"o-fam","name":"Familia","status":2,"type":2}]' BW_DENY_EXPORT=o-fam
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
mkdir -p "$SP/sbx/out/20200101000000-bw-export" "$SP/sbx/out/20200102000000-bw-export"
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "attempted" "$(grep -q '^bw export --organizationid o-fam ' "$BW_CALLLOG"; echo $?)" "$(grep '^bw export' "$BW_CALLLOG")"
check "hint names the role" "$(grep -q 'Hint: your role (User) cannot export it' "$SP/sbx/output" && grep -q 'Remove it from BW_ORGANIZATIONS_LIST' "$SP/sbx/output"; echo $?)" "$(grep -A2 'Failed to export' "$SP/sbx/output")"
# The refusal logs the CLI out. Run before it, the attachments survive it.
check "attachments saved before the refusal" "$(compgen -G "$SP/sbx/att/*/Doc/a.pdf" >/dev/null; echo $?)" "$(grep -i 'attach\|not logged' "$SP/sbx/output")"
check "no listing failure" "$(grep -q '1 vault export(s) and 0 vault listing(s) failed' "$SP/sbx/output"; echo $?)" "$(grep 'failed' "$SP/sbx/output")"
check "old backups kept" "$([ -d "$SP/sbx/out/20200101000000-bw-export" ] && [ -d "$SP/sbx/out/20200102000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"

echo "=== T37b: a role or status the CLI does not report as a number is tried, as before ==="
setup ""
export BW_REAL_PW=correct-pw BW_ORGS_JSON='[{"id":"o0","name":"NoRole"},{"id":"o1","name":"Str","status":"Confirmed","type":"User"}]'
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "both attempted" "$([ "$(grep -c '^bw export --organizationid' "$BW_CALLLOG")" = 2 ]; echo $?)" "$(grep '^bw export --org' "$BW_CALLLOG")"
check "nothing skipped" "$(! grep -q 'Skipping organization' "$SP/sbx/output"; echo $?)" "$(grep 'Skipping' "$SP/sbx/output")"

echo "=== T37c: an organizations listing that is not JSON is a failed listing ==="
setup ""
export BW_REAL_PW=correct-pw BW_ORGS_JSON='Could not find data file; creating it instead.'
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says it could not list" "$(grep -q 'Could not list the organizations' "$SP/sbx/output"; echo $?)" "$(grep -i 'organi' "$SP/sbx/output")"
check "no 'No organizational vault exists'" "$(! grep -q 'No organizational vault exists' "$SP/sbx/output"; echo $?)" "claimed there are none"

echo "=== T38: an explicit list does not depend on listing the organizations ==="
setup ""
# There the listing only feeds the hint, so it failing is not a failed backup.
export BW_REAL_PW=correct-pw BW_ORGANIZATIONS_LIST=o1 BW_FAIL_LIST=organizations
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(grep -i 'error' "$SP/sbx/output")"
check "exported" "$(compgen -G "$SP/sbx/out/*/export-o1.json" >/dev/null; echo $?)" "$(find "$SP/sbx/out" -type f)"
check "no listing error logged" "$(! grep -q 'Could not list\|not logged in' "$SP/sbx/output"; echo $?)" "$(grep -i 'list\|logged' "$SP/sbx/output")"

echo "=== T39: BW_ORGANIZATIONS_LIST=none exports no organization ==="
for value in none " NoNe "; do
  setup ""
  export BW_REAL_PW=correct-pw BW_ORGANIZATIONS_LIST="$value" \
         BW_ORGS_JSON='[{"id":"o0","name":"Own","status":2,"type":0}]'
  rc=$(run)
  check "[$value] exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
  check "[$value] organizations not even listed" "$(! grep -q '^bw list organizations\|^bw export --organizationid' "$BW_CALLLOG"; echo $?)" "$(grep 'organi' "$BW_CALLLOG")"
  check "[$value] says so" "$(grep -q 'BW_ORGANIZATIONS_LIST is none' "$SP/sbx/output"; echo $?)" "$(grep -i 'organi' "$SP/sbx/output")"
  check "[$value] personal vault saved" "$(exported; echo $?)" "no export file"
done

echo "=== T40: each saved attachment gets a line of its own ==="
setup ""
# The CLI prints "Saved <path>" with no newline; passed through as is, every
# attachment ran into one line, and log viewers cut that line short.
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"},{"fileName":"b.txt"}]},{"id":"i2","name":"Key","attachments":[{"fileName":"c.key"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "three Saved lines" "$([ "$(grep -c '^Saved .*/att/.*/\(Doc/a\.pdf\|Doc/b\.txt\|Key/c\.key\)$' "$SP/sbx/output")" = 3 ]; echo $?)" "$(grep 'Saved' "$SP/sbx/output")"
check "never two on one line" "$(! grep -q 'Saved .*Saved' "$SP/sbx/output"; echo $?)" "$(grep 'Saved.*Saved' "$SP/sbx/output")"
check "a failed one is still counted" "$(export BW_FAIL_ATTACH=b.txt; rc=$(run); [ "$rc" = 1 ] && grep -q '1 attachment(s) could not be saved' "$SP/sbx/output"; echo $?)" "$(grep -i 'attach' "$SP/sbx/output")"

echo "=== TM: an anonymous volume is told apart from a real mount (mountinfo) ==="
setup ""
# The legacy /var/attachment fallback hinges on this, and rootful Docker cannot
# be run here, so its mountinfo format is checked from fixture lines. The
# function is pulled out of the script, since sourcing the script would run it.
eval "$(sed -n '/^is_anonymous_volume() {/,/^}/p' "$SCRIPT")"
id=$(printf '%064d' 0)
cat > "$SP/sbx/mountinfo" <<EOF
101 90 0:52 /var/lib/docker/volumes/$id/_data /docker-anon rw - ext4 /dev/sda1 rw
102 90 0:52 /lib/docker/volumes/$id/_data /docker-anon-sepvar rw - xfs /dev/sdb1 rw
103 90 0:52 /home/u/.local/share/containers/storage/volumes/$id/_data /podman-anon rw - btrfs /dev/sda2 rw
104 90 0:52 /var/lib/docker/volumes/my-attachments/_data /named rw - ext4 /dev/sda1 rw
105 90 0:52 /srv/backups/attachments /bind rw - ext4 /dev/sda1 rw
106 90 0:52 /srv/volumes/$id/_data/sub /bind-lookalike rw - ext4 /dev/sda1 rw
EOF
if ! declare -F is_anonymous_volume >/dev/null; then
  check "the script defines is_anonymous_volume" 1 "not found in $SCRIPT"
else
  for m in /docker-anon /docker-anon-sepvar /podman-anon; do
    check "$m is anonymous" "$(is_anonymous_volume "$m" "$SP/sbx/mountinfo"; echo $?)" "not detected"
  done
  for m in /named /bind /bind-lookalike /not-mounted; do
    check "$m is not anonymous" "$(! is_anonymous_volume "$m" "$SP/sbx/mountinfo"; echo $?)" "misdetected"
  done
fi

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
