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
export LOG_LIB="$SP/../root/usr/local/lib/bw-export/log.sh"
SCRIPT="${SCRIPT:?}"
# The script sources it from where the image installs it; here, the repository.
export SECRETS_LIB="$SP/../root/usr/local/lib/bw-export/secrets.sh"
export RETENTION_LIB="$SP/../root/usr/local/lib/bw-export/retention.sh"
pass=0; fail=0

# Sets up a fresh sandbox; $1 = a snippet that seeds the CLI state file.
setup() {
  unset PW BW_FAIL_CONFIG BW_FAIL_LOGIN BW_FAIL_LOGOUT BITWARDENCLI_APPDATA_DIR \
        BW_ITEMS_FILE BW_ATTACHLOG BW_FAIL_ATTACH KEEP_LAST_BACKUPS \
        BW_FAIL_EXPORT BW_ORGANIZATIONS_LIST BW_FAIL_LIST EXP BW_EXPORT_NOFILE \
        BW_ORGS_JSON BW_DENY_EXPORT ENCRYPT_ATTACHMENTS KEEP_GFS TMPDIR \
        BACKUP_PERMISSIONS BW_WRAP_DIR
  rm -rf "$SP/sbx"; mkdir -p "$SP/sbx/out" "$SP/sbx/att"
  export BW_STATE="$SP/sbx/state" BW_CALLLOG="$SP/sbx/calls"
  : > "$BW_CALLLOG"
  [ -n "$1" ] && printf '%s\n' "$1" > "$BW_STATE"
}

run() {
  # BW_WRAP_DIR: a folder searched before the mock, for a test's own bw.
  ( export PATH="${BW_WRAP_DIR:+$BW_WRAP_DIR:}$SP/mock:$PATH" \
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
check "logs what it will do, without values" "$(grep -q 'INFO: Server: self-hosted, version unknown' "$SP/sbx/output" && grep -q 'INFO: Credentials: BW_CLIENTID set, BW_CLIENTSECRET set, BW_PASSWORD set' "$SP/sbx/output" && grep -q 'INFO: Vault export: encrypted with EXPORT_PASSWORD (set)' "$SP/sbx/output"; echo $?)" "$(grep -E 'Server:|Credentials:|Vault export:' "$SP/sbx/output")"
check "no secret value and no colour code in the log" "$(! grep -qE 'correct-pw|secret$|=exp|vw\.example\.com' "$SP/sbx/output" && ! grep -q $'\e' "$SP/sbx/output"; echo $?)" "$(grep -nE 'correct-pw|vw\.example\.com' "$SP/sbx/output"; grep -c $'\e' "$SP/sbx/output")"
check "every log line has the one format" "$(! grep -vE '^$|^(Saved|----- Summary|-------------------|Duration|Personal vault|Organizations|Attachments|Trash|Backup size|Old backups deleted)|^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} (INFO|WARNING|ERROR|HINT): ' "$SP/sbx/output" | grep -q .; echo $?)" "$(grep -vE '^$|^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} (INFO|WARNING|ERROR|HINT): ' "$SP/sbx/output" | head -5)"

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
check "reports server error" "$(grep -q 'Failed to set the server URL' "$SP/sbx/output"; echo $?)" "no message"
check "never logs the server address" "$(! grep -q 'vw.example.com' "$SP/sbx/output"; echo $?)" "$(grep 'vw.example.com' "$SP/sbx/output")"
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
check "announces saving, with counts" "$(grep -qE 'Saving [0-9]+ attachment\(s\) from [0-9]+ item\(s\)' "$SP/sbx/output"; echo $?)" "$(grep -i attach "$SP/sbx/output")"
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
check "no 'Export finished successfully'" "$(! grep -q 'Export finished successfully' "$SP/sbx/output"; echo $?)" "reported success anyway"
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
check "reports success" "$(grep -q 'Export finished successfully' "$SP/sbx/output"; echo $?)" "no success message"
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
check "says it is keeping them" "$(grep -q 'so no old backup is deleted for it' "$SP/sbx/output"; echo $?)" "$(tail -5 "$SP/sbx/output")"
check "old vault backups untouched" "$([ -d "$SP/sbx/out/20200101000000-bw-export" ] && [ -d "$SP/sbx/out/20200102000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "old attachment backups untouched" "$([ -d "$SP/sbx/att/20200101000000-bw-export" ] && [ -d "$SP/sbx/att/20200102000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/att")"
check "did not run the cleanup" "$(! grep -q 'Rotating old backups' "$SP/sbx/output"; echo $?)" "pruned anyway"

echo "=== T24: a complete export still rotates as configured ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
mkdir -p "$SP/sbx/out/20200101000000-bw-export" "$SP/sbx/out/20200102000000-bw-export"
printf '%s' '[{"id":"i1","name":"Ok","attachments":[{"fileName":"good.txt"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json" KEEP_LAST_BACKUPS=1
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "ran the cleanup" "$(grep -q 'Rotating old backups' "$SP/sbx/output"; echo $?)" "skipped it"
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
check "no 'Export finished successfully'" "$(! grep -q 'Export finished successfully' "$SP/sbx/output"; echo $?)" "reported success anyway"
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
check "says it is keeping them" "$(grep -q 'so no old backup is deleted for it' "$SP/sbx/output"; echo $?)" "$(tail -5 "$SP/sbx/output")"
check "old backups untouched" "$([ -d "$SP/sbx/out/20200101000000-bw-export" ] && [ -d "$SP/sbx/out/20200102000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "did not run the cleanup" "$(! grep -q 'Rotating old backups' "$SP/sbx/output"; echo $?)" "pruned anyway"

echo "=== T28: exports with organizations all succeeding must still exit 0 ==="
setup ""
export BW_REAL_PW=correct-pw BW_ORGANIZATIONS_LIST=o1,o2
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "reports completion" "$(grep -q 'Vault export complete' "$SP/sbx/output" && grep -q 'Export finished successfully' "$SP/sbx/output"; echo $?)" "$(tail -4 "$SP/sbx/output")"
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
check "no 'Export finished successfully'" "$(! grep -q 'Export finished successfully' "$SP/sbx/output"; echo $?)" "reported success anyway"
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
check "says why, by ID" "$(grep -q 'Skipping organization o-fam: your role (User) cannot export it' "$SP/sbx/output"; echo $?)" "$(grep -i 'organi' "$SP/sbx/output")"
check "never logs its name" "$(! grep -q 'Familia' "$SP/sbx/output"; echo $?)" "$(grep 'Familia' "$SP/sbx/output")"
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
check "Manager by ID" "$(grep -q 'organization o3: your role (Manager) cannot export it' "$SP/sbx/output"; echo $?)" "$(grep 'o3' "$SP/sbx/output")"
check "Custom by ID, with the way out" "$(grep -q 'organization o4: the CLI cannot tell whether your role (Custom) may export it' "$SP/sbx/output" && grep -A1 'organization o4:' "$SP/sbx/output" | grep -q 'add its ID to BW_ORGANIZATIONS_LIST'; echo $?)" "$(grep -A1 'o4' "$SP/sbx/output")"
check "unconfirmed by ID" "$(grep -q 'organization o5: your membership is not confirmed' "$SP/sbx/output"; echo $?)" "$(grep 'o5' "$SP/sbx/output")"
check "revoked by ID" "$(grep -q 'organization o6: your access to it is revoked' "$SP/sbx/output"; echo $?)" "$(grep 'o6' "$SP/sbx/output")"
check "no organization name in the log, so no escape from one" "$(! grep -q 'Rev' "$SP/sbx/output" && ! grep -q $'\e' "$SP/sbx/output"; echo $?)" "$(grep 'o6' "$SP/sbx/output" | od -c | head -3)"

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
check "hint names the role" "$(grep -q 'HINT: your role (User) cannot export it' "$SP/sbx/output" && grep -q 'Remove it from BW_ORGANIZATIONS_LIST' "$SP/sbx/output"; echo $?)" "$(grep -A2 'Failed to export' "$SP/sbx/output")"
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

echo "=== T40: the log names no item and no attachment, only counts and item IDs ==="
setup ""
# Item and file names are vault data (a person's name, an ID number), and a log
# is what gets pasted into a support request. The CLI's "Saved <path>" carries
# both, so it is not logged.
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
printf '%s' '[{"id":"i1","name":"Jane Doe Passport","attachments":[{"fileName":"passport-12345678Z.pdf"},{"fileName":"b.txt"}]},{"id":"i2","name":"Key","attachments":[{"fileName":"c.key"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "all three saved" "$([ "$(find "$SP/sbx/att" -type f | wc -l)" = 3 ]; echo $?)" "$(find "$SP/sbx/att" -type f)"
check "no item or file name in the log" "$(! grep -qE 'Jane|Passport|12345678Z|b\.txt|c\.key' "$SP/sbx/output"; echo $?)" "$(grep -E 'Jane|Passport|12345678Z|b\.txt|c\.key' "$SP/sbx/output")"
check "counts instead" "$(grep -q 'Saving 3 attachment(s) from 2 item(s)' "$SP/sbx/output" && grep -q 'Attachments: 3 saved, 0 failed\.$' "$SP/sbx/output"; echo $?)" "$(grep -i attach "$SP/sbx/output")"
rc=$(export BW_FAIL_ATTACH=b.txt; run)
check "a failed one is counted" "$([ "$rc" = 1 ] && grep -q '1 attachment(s) could not be saved' "$SP/sbx/output"; echo $?)" "$(grep -i 'attach' "$SP/sbx/output")"
check "the CLI's message under the warning" "$(grep -A1 'Attachment 2 of 3' "$SP/sbx/output" | grep -q '^    bw: An error occurred while saving the attachment\.$'; echo $?)" "$(grep -A1 'Attachment 2 of 3' "$SP/sbx/output")"
check "the proxy hint, since the CLI could not save it" "$(grep -q 'HINT: The CLI could not decrypt or save' "$SP/sbx/output"; echo $?)" "$(grep HINT "$SP/sbx/output")"
check "and named by position and item ID only" "$(grep -q 'Attachment 2 of 3 (item i1) could not be saved' "$SP/sbx/output" && ! grep -q 'b\.txt' "$SP/sbx/output"; echo $?)" "$(grep -i 'attachment 2' "$SP/sbx/output")"
rc=$(export BW_FAIL_ATTACH=b.txt BW_FAIL_ATTACH_MSG="Not found."; run)
check "another cause: no proxy hint, the CLI's message instead" "$([ "$rc" = 1 ] && grep -q '^    bw: Not found\.$' "$SP/sbx/output" && ! grep -q 'reverse proxy' "$SP/sbx/output" && grep -q "HINT: The Bitwarden CLI's own message is under each warning above" "$SP/sbx/output"; echo $?)" "$(grep -E 'bw:|HINT' "$SP/sbx/output")"

echo "=== T41: an EXPORT_PASSWORD that yields no password never exports unencrypted ==="
# A folder is what Docker makes of a bind-mounted secret file that does not
# exist; /run/secrets/<name> unmounted and an empty file are the other two ways.
mkdir -p "$SP/sbx-t41/folder"; : > "$SP/sbx-t41/empty"
for exp in "$SP/sbx-t41/folder" "$SP/sbx-t41/empty" "/run/secrets/bw-export-test-not-mounted"; do
  setup ""
  export BW_REAL_PW=correct-pw EXP="$exp"
  rc=$(run)
  check "[${exp##*/}] exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
  check "[${exp##*/}] nothing exported" "$(! grep -q '^bw export' "$SP/sbx/calls" && [ -z "$(find "$SP/sbx/out" -type f)" ]; echo $?)" "$(grep '^bw export' "$SP/sbx/calls")"
  check "[${exp##*/}] says why" "$(grep -q 'EXPORT_PASSWORD is set, but no password could be read' "$SP/sbx/output"; echo $?)" "$(grep -i 'export_password' "$SP/sbx/output")"
done
rm -rf "$SP/sbx-t41"

echo "=== T42: a credential under /run/secrets that is not mounted stops the run ==="
setup ""
export BW_REAL_PW=correct-pw PW=/run/secrets/bw-export-test-not-mounted
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "never logged in" "$(! grep -q '^bw login' "$SP/sbx/calls"; echo $?)" "$(grep '^bw login' "$SP/sbx/calls")"
check "names the variable" "$(grep -q 'BW_PASSWORD is set, but no value could be read' "$SP/sbx/output"; echo $?)" "$(grep -i 'bw_password' "$SP/sbx/output")"
check "the path is not the password" "$([ ! -e "$SP/sbx/state" ] || ! grep -q 'bw-export-test-not-mounted' "$SP/sbx/state"; echo $?)" "$(cat "$SP/sbx/state" 2>/dev/null)"

echo "=== T43: a literal password that starts with / is used as is, without a warning ==="
setup ""
export BW_REAL_PW=/Passw0rd PW=/Passw0rd EXP=/Export-pw
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"
check "export got it verbatim" "$(grep -qxF 'personal	/Export-pw' "$SP/sbx/pwlog"; echo $?)" "pwlog: $(cut -f1 "$SP/sbx/pwlog")"
check "no warning" "$(! grep -qi 'warning: .*\(BW_PASSWORD\|EXPORT_PASSWORD\)' "$SP/sbx/output"; echo $?)" "$(grep -i warning "$SP/sbx/output")"
unset EXP

# run(), but with every credential given through its _FILE variable instead.
run_files() {
  ( export PATH="$SP/mock:$PATH" \
      OUTPUT_PATH="$SP/sbx/out" ATTACHMENTS_PATH="$SP/sbx/att" \
      BW_URL_SERVER="https://vw.example.com" BW_EXPORT_PWLOG="$SP/sbx/pwlog" \
      BW_CLIENTID_FILE="$SP/sbx/f/id" BW_CLIENTSECRET_FILE="$SP/sbx/f/secret" \
      BW_PASSWORD_FILE="$SP/sbx/f/pw" EXPORT_PASSWORD_FILE="${EXPF:-$SP/sbx/f/exp}"
    unset BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD EXPORT_PASSWORD
    [ -n "${BOTH:-}" ] && export BW_PASSWORD=also-set
    bash "$SCRIPT" ) > "$SP/sbx/output" 2>&1
  echo $?
}
files_setup() {
  setup ""
  mkdir -p "$SP/sbx/f"
  printf 'id-from-file\n' > "$SP/sbx/f/id"; printf 'secret-from-file\r\n' > "$SP/sbx/f/secret"
  printf 'master-from-file\n' > "$SP/sbx/f/pw"; printf 'export-from-file\n' > "$SP/sbx/f/exp"
  export BW_REAL_PW=master-from-file
}

echo "=== T44: every credential through its _FILE variable ==="
files_setup
rc=$(run_files)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(grep -i 'error\|warning' "$SP/sbx/output")"
check "login got the key from the files" "$(grep -qxF 'APIKEY=id-from-file:secret-from-file' "$SP/sbx/calls"; echo $?)" "$(grep '^APIKEY' "$SP/sbx/calls")"
check "unlocked with the file's password" "$(grep -q '^bw unlock' "$SP/sbx/calls" && exported; echo $?)" "$(tail -3 "$SP/sbx/output")"
check "encrypted with the file's password" "$(grep -qxF 'personal	export-from-file' "$SP/sbx/pwlog"; echo $?)" "pwlog: $(cut -f1 "$SP/sbx/pwlog")"
check "no value in argv" "$(! grep -q 'master-from-file\|export-from-file' "$SP/sbx/calls"; echo $?)" "$(grep 'from-file' "$SP/sbx/calls")"

echo "=== T45: an EXPORT_PASSWORD_FILE that cannot be read never exports unencrypted ==="
files_setup
rc=$(EXPF="$SP/sbx/f/missing" run_files)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "nothing exported" "$(! grep -q '^bw export' "$SP/sbx/calls"; echo $?)" "$(grep '^bw export' "$SP/sbx/calls")"
check "says which file" "$(grep -q 'EXPORT_PASSWORD_FILE points to a file that does not exist' "$SP/sbx/output"; echo $?)" "$(grep -i 'export_password' "$SP/sbx/output")"

echo "=== T46: BW_PASSWORD and BW_PASSWORD_FILE both set stop the run ==="
files_setup
rc=$(BOTH=1 run_files)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says both are set" "$(grep -q 'BW_PASSWORD and BW_PASSWORD_FILE are both set' "$SP/sbx/output"; echo $?)" "$(grep -i 'bw_password' "$SP/sbx/output")"
check "never logged in" "$(! grep -q '^bw login' "$SP/sbx/calls"; echo $?)" "$(grep '^bw login' "$SP/sbx/calls")"
unset BW_REAL_PW

REAL_GPG=$(command -v gpg)
# Lists what an attachments archive holds, decrypted with $2.
archive_list() {
  local h; h=$(mktemp -d)
  "$REAL_GPG" --homedir "$h" --batch --quiet --pinentry-mode loopback --passphrase "$2" -d "$1" 2>/dev/null | tar -tzf - 2>/dev/null | sort | paste -sd' ' -
  gpgconf --homedir "$h" --kill gpg-agent >/dev/null 2>&1; rm -rf "$h"
}
archive() { compgen -G "$SP/sbx/att/*-bw-export/attachments.tar.gz.gpg" | head -n 1; }
plain_attachments() { find "$SP/sbx/att" -type f ! -name 'attachments.tar.gz.gpg' | wc -l; }

echo "=== T47: ENCRYPT_ATTACHMENTS packs the attachments into one encrypted archive ==="
setup ""
mkdir -p "$SP/sbx/tmp" "$SP/sbx/gpgwrap"
# A gpg that records its arguments, to prove the password never reaches them.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$SP/sbx/gpgargs" "$REAL_GPG" > "$SP/sbx/gpgwrap/gpg"
chmod +x "$SP/sbx/gpgwrap/gpg"
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach" ENCRYPT_ATTACHMENTS=true TMPDIR="$SP/sbx/tmp" EXP='s3cret export pw'
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"},{"fileName":"b.txt"}]},{"id":"i2","name":".ssh","attachments":[{"fileName":"id_ed25519"}]}]' \
  > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(PATH="$SP/sbx/gpgwrap:$PATH" run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -5 "$SP/sbx/output")"
check "one archive written" "$([ -s "$(archive)" ]; echo $?)" "$(find "$SP/sbx/att")"
check "no plain attachment in the volume" "$([ "$(plain_attachments)" = 0 ]; echo $?)" "$(find "$SP/sbx/att" -type f)"
check "decrypts with EXPORT_PASSWORD to every file" \
  "$([ "$(archive_list "$(archive)" 's3cret export pw' | tr ' ' '\n' | grep -c '[^/]$')" = 3 ]; echo $?)" "$(archive_list "$(archive)" 's3cret export pw')"
check "no ./ entry (restoring would chmod the target)" "$(! archive_list "$(archive)" 's3cret export pw' | tr ' ' '\n' | grep -qx '\./'; echo $?)" "$(archive_list "$(archive)" 's3cret export pw')"
check "a wrong password does not decrypt it" "$([ -z "$(archive_list "$(archive)" wrong)" ]; echo $?)" "decrypted with a wrong password"
check "staging folder removed" "$([ -z "$(ls -A "$SP/sbx/tmp")" ]; echo $?)" "$(ls -A "$SP/sbx/tmp")"
check "no .part file left" "$([ -z "$(find "$SP/sbx/att" -name '*.part')" ]; echo $?)" "$(find "$SP/sbx/att" -name '*.part')"
check "password never in gpg's arguments" "$(! grep -q 's3cret' "$SP/sbx/gpgargs"; echo $?)" "$(cat "$SP/sbx/gpgargs")"
check "summary says encrypted archive" "$(grep -q '^Attachments: 3 saved, 0 failed (encrypted archive)$' "$SP/sbx/output"; echo $?)" "$(grep '^Attachments' "$SP/sbx/output")"

echo "=== T48: ENCRYPT_ATTACHMENTS without EXPORT_PASSWORD stops before touching the CLI ==="
setup ""
export BW_REAL_PW=correct-pw ENCRYPT_ATTACHMENTS=true EXP=''
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says why" "$(grep -q 'ENCRYPT_ATTACHMENTS is on, but EXPORT_PASSWORD is not set' "$SP/sbx/output"; echo $?)" "$(grep ERROR "$SP/sbx/output")"
check "no bw calls made" "$([ ! -s "$SP/sbx/calls" ]; echo $?)" "$(cat "$SP/sbx/calls")"

echo "=== T49: ENCRYPT_ATTACHMENTS values ==="
setup ""
export BW_REAL_PW=correct-pw
rc=$(export ENCRYPT_ATTACHMENTS=maybe; run)
check "an unknown value is an error" "$([ "$rc" = 1 ] && grep -q 'ENCRYPT_ATTACHMENTS must be true or false' "$SP/sbx/output"; echo $?)" "rc=$rc"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
for v in false FALSE no off 0 ''; do
  setup ""; export BW_REAL_PW=correct-pw BW_ITEMS_FILE="$SP/sbx/items.json"
  printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
  rc=$(export ENCRYPT_ATTACHMENTS="$v"; run)
  check "'$v' keeps plain attachments, as before" "$([ "$rc" = 0 ] && compgen -G "$SP/sbx/att/*/Doc/a.pdf" >/dev/null && [ -z "$(archive)" ]; echo $?)" "rc=$rc $(find "$SP/sbx/att" -type f)"
done
setup ""; export BW_REAL_PW=correct-pw BW_ITEMS_FILE="$SP/sbx/items.json"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
rc=$(export ENCRYPT_ATTACHMENTS=YES; run)
check "'YES' encrypts" "$([ "$rc" = 0 ] && [ -s "$(archive)" ] && [ "$(plain_attachments)" = 0 ]; echo $?)" "rc=$rc $(find "$SP/sbx/att" -type f)"
setup ""; export BW_REAL_PW=correct-pw
rc=$(export ENCRYPT_ATTACHMENTS=true; run)
check "no attachments: no archive, still exit 0" "$([ "$rc" = 0 ] && [ -z "$(archive)" ] && grep -q 'No attachments exist' "$SP/sbx/output"; echo $?)" "rc=$rc"

echo "=== T50: a failed download is still encrypted around, and the run fails ==="
setup ""
mkdir -p "$SP/sbx/tmp"
export BW_REAL_PW=correct-pw ENCRYPT_ATTACHMENTS=true BW_FAIL_ATTACH=bad.txt TMPDIR="$SP/sbx/tmp"
printf '%s' '[{"id":"i1","name":"Ok","attachments":[{"fileName":"good.txt"},{"fileName":"bad.txt"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "the good one is in the archive" "$(archive_list "$(archive)" exp | grep -q 'Ok/good.txt'; echo $?)" "$(archive_list "$(archive)" exp)"
check "no plain attachment in the volume" "$([ "$(plain_attachments)" = 0 ]; echo $?)" "$(find "$SP/sbx/att" -type f)"
check "staging folder removed" "$([ -z "$(ls -A "$SP/sbx/tmp")" ]; echo $?)" "$(ls -A "$SP/sbx/tmp")"
unset BW_FAIL_ATTACH

echo "=== T51: if encryption fails nothing is kept in the clear, and the run fails ==="
setup ""
mkdir -p "$SP/sbx/tmp" "$SP/sbx/badgpg"
# It writes part of its output first, as a gpg killed or out of space would.
cat > "$SP/sbx/badgpg/gpg" <<'GPG'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = --output ] && printf 'partial' > "$2"; shift; done
echo "gpg: encryption failed" >&2
exit 2
GPG
chmod +x "$SP/sbx/badgpg/gpg"
export BW_REAL_PW=correct-pw ENCRYPT_ATTACHMENTS=true TMPDIR="$SP/sbx/tmp" KEEP_LAST_BACKUPS=1
mkdir -p "$SP/sbx/att/20200101000000-bw-export"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(PATH="$SP/sbx/badgpg:$PATH" run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "says so" "$(grep -q 'attachments could not be encrypted' "$SP/sbx/output"; echo $?)" "$(grep ERROR "$SP/sbx/output")"
check "no archive and no plain file anywhere" "$([ -z "$(archive)" ] && [ "$(plain_attachments)" = 0 ] && [ -z "$(ls -A "$SP/sbx/tmp")" ]; echo $?)" "$(find "$SP/sbx/att" "$SP/sbx/tmp")"
check "no half-written archive left" "$([ -z "$(find "$SP/sbx/att" -name '*.part')" ]; echo $?)" "$(find "$SP/sbx/att" -name '*.part')"
check "older backups not rotated out" "$([ -d "$SP/sbx/att/20200101000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/att")"
check "summary reports it" "$(grep -q '^Attachments: 1 saved, 0 failed (encryption FAILED, none kept)$' "$SP/sbx/output"; echo $?)" "$(grep '^Attachments' "$SP/sbx/output")"
unset KEEP_LAST_BACKUPS

echo "=== T52: KEEP_GFS rotates both folders by day, week and month ==="
setup ""
export BW_REAL_PW=correct-pw KEEP_GFS=2d:1m
for d in 20200101000000 20200102000000 20200115000000 20200201000000 20200202000000; do
  mkdir -p "$SP/sbx/out/$d-bw-export" "$SP/sbx/att/$d-bw-export"
done
# Not backups: never touched, whatever their name.
mkdir -p "$SP/sbx/out/my-notes-bw-export" "$SP/sbx/out/20200101000000-bw-export/inner/20190101000000-bw-export"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -5 "$SP/sbx/output")"
# Kept: this run (today, its own day and month) and 2020-02-02 (the 2nd day).
check "vault folders kept" "$([ "$(find "$SP/sbx/out" -mindepth 1 -maxdepth 1 -name '2020*' | sort | xargs -n1 basename | paste -sd' ' -)" = "20200202000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "attachment folders kept" "$([ "$(find "$SP/sbx/att" -mindepth 1 -maxdepth 1 -name '2020*' | sort | xargs -n1 basename | paste -sd' ' -)" = "20200202000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/att")"
check "this run's folders kept" "$(exported; echo $?)" "$(ls "$SP/sbx/out")"
check "a folder that only looks like one kept" "$([ -d "$SP/sbx/out/my-notes-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "summary counts the deletions" "$(grep -q '^Old backups deleted: 8$' "$SP/sbx/output"; echo $?)" "$(grep '^Old backups' "$SP/sbx/output")"

echo "=== T53: an invalid KEEP_GFS still backs up, deletes nothing and fails ==="
setup ""
export BW_REAL_PW=correct-pw KEEP_GFS=7days KEEP_LAST_BACKUPS=1
mkdir -p "$SP/sbx/out/20200101000000-bw-export"
rc=$(run)
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "the export was written" "$(exported; echo $?)" "$(ls "$SP/sbx/out")"
check "nothing deleted" "$([ -d "$SP/sbx/out/20200101000000-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "says why" "$(grep -q 'KEEP_GFS=7days is not valid' "$SP/sbx/output" && grep -q 'old backups were not rotated' "$SP/sbx/output"; echo $?)" "$(grep ERROR "$SP/sbx/output")"
unset KEEP_GFS KEEP_LAST_BACKUPS

echo "=== T54: KEEP_LAST_BACKUPS keeps its meaning, and a folder name with spaces is safe ==="
setup ""
export BW_REAL_PW=correct-pw KEEP_LAST_BACKUPS=2
mkdir -p "$SP/sbx/out/20200101000000-bw-export" "$SP/sbx/out/20200102000000-bw-export" "$SP/sbx/out/a b-bw-export"
rc=$(run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "only the oldest went" "$([ ! -d "$SP/sbx/out/20200101000000-bw-export" ] && [ -d "$SP/sbx/out/20200102000000-bw-export" ] && [ -d "$SP/sbx/out/a b-bw-export" ]; echo $?)" "$(ls "$SP/sbx/out")"
check "rejects a non-number as before" "$(export KEEP_LAST_BACKUPS=x; rc=$(run); [ "$rc" = 1 ] && grep -q 'KEEP_LAST_BACKUPS=x is not a number' "$SP/sbx/output"; echo $?)" "$(grep ERROR "$SP/sbx/output")"
unset KEEP_LAST_BACKUPS

echo "=== T55: the summary says what the run did ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach" BW_FAIL_ATTACH=bad.txt
export BW_ORGS_JSON='[{"id":"o1","name":"Mine","status":2,"type":0},{"id":"o2","name":"Shared","status":2,"type":2}]'
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"},{"fileName":"bad.txt"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
summary=$(sed -n '/^----- Summary -----$/,/^-------------------$/p' "$SP/sbx/output")
check "exit 1 (an attachment failed)" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "has a duration" "$(grep -qE '^Duration: [0-9]+s$' <<<"$summary"; echo $?)" "$summary"
check "personal vault" "$(grep -qx 'Personal vault: exported (encrypted)' <<<"$summary"; echo $?)" "$summary"
check "organizations" "$(grep -qx 'Organizations: 1 exported, 1 skipped, 0 failed' <<<"$summary"; echo $?)" "$summary"
check "attachments" "$(grep -qx 'Attachments: 1 saved, 1 failed (unencrypted)' <<<"$summary"; echo $?)" "$summary"
check "has a size" "$(grep -qE '^Backup size: [0-9.]+[KMGT]?i?B$' <<<"$summary"; echo $?)" "$summary"
check "errors come after it" "$([ "$(grep -n 'attachment(s) are missing' "$SP/sbx/output" | cut -d: -f1)" -gt "$(grep -n '^-------------------$' "$SP/sbx/output" | cut -d: -f1)" ]; echo $?)" "$(tail -8 "$SP/sbx/output")"
unset BW_FAIL_ATTACH BW_ORGS_JSON
setup ""
export BW_REAL_PW=correct-pw BW_FAIL_EXPORT=personal BW_ORGANIZATIONS_LIST=none EXP=''
rc=$(run)
summary=$(sed -n '/^----- Summary -----$/,/^-------------------$/p' "$SP/sbx/output")
check "a failed personal export" "$(grep -qx 'Personal vault: FAILED' <<<"$summary"; echo $?)" "$summary"
check "BW_ORGANIZATIONS_LIST=none" "$(grep -qx 'Organizations: none (BW_ORGANIZATIONS_LIST=none)' <<<"$summary"; echo $?)" "$summary"
setup ""
export BW_REAL_PW=correct-pw EXP=''
rc=$(run)
check "unencrypted vault" "$(grep -qx 'Personal vault: exported (unencrypted)' "$SP/sbx/output"; echo $?)" "$(grep '^Personal' "$SP/sbx/output")"
check "no summary when login fails" "$(export BW_FAIL_LOGIN=1; run >/dev/null; ! grep -q 'Summary' "$SP/sbx/output"; echo $?)" "printed one"
unset BW_FAIL_EXPORT BW_ORGANIZATIONS_LIST


echo "=== T55b: a folder this user cannot write to is named before anything runs ==="
if [ "$(id -u)" = 0 ]; then
  echo "  SKIP  root can write to any folder; run the suite as a normal user (CI does)"
else
  setup ""
  export BW_REAL_PW=correct-pw
  chmod 555 "$SP/sbx/out"
  rc=$(run)
  chmod 755 "$SP/sbx/out"
  check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
  check "names the folder and the uid" "$(grep -q "Cannot write to $SP/sbx/out as uid $(id -u)" "$SP/sbx/output"; echo $?)" "$(grep ERROR "$SP/sbx/output")"
  check "no bw calls made" "$([ ! -s "$SP/sbx/calls" ]; echo $?)" "$(cat "$SP/sbx/calls")"
fi

# Every file and folder a run wrote under $1, with its mode, one per line.
run_modes() { find "$1" -mindepth 1 -printf '%m %P\n' | sort -k2; }
# Anything under $1's run folders that group or others can touch.
open_to_others() { find "$SP/sbx/out" "$SP/sbx/att" -mindepth 2 -perm /077; }

echo "=== T56: without BACKUP_PERMISSIONS the modes are what they always were ==="
# The mock writes its files with the umask, as a plain program does; the real
# CLI writes 600 and 700 whatever the umask. What is checked here is that the
# script itself changes nothing without the variable.
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach" BW_ITEMS_FILE="$SP/sbx/items.json"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
rc=$(umask 022; run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "run folder is 755" "$([ "$(stat -c %a "$SP"/sbx/out/*-bw-export)" = 755 ]; echo $?)" "$(run_modes "$SP/sbx/out")"
check "attachments folders are 755" "$([ "$(stat -c %a "$SP"/sbx/att/*-bw-export "$SP"/sbx/att/*-bw-export/Doc | sort -u)" = 755 ]; echo $?)" "$(run_modes "$SP/sbx/att")"
check "files follow the umask, as before (644)" "$([ "$(stat -c %a "$SP"/sbx/out/*-bw-export/*.json "$SP"/sbx/att/*-bw-export/Doc/a.pdf | sort -u)" = 644 ]; echo $?)" "$(run_modes "$SP/sbx")"
check "does not mention it" "$(! grep -q 'BACKUP_PERMISSIONS' "$SP/sbx/output"; echo $?)" "$(grep BACKUP "$SP/sbx/output")"
for v in default DEFAULT; do
  setup ""; export BW_REAL_PW=correct-pw BW_ITEMS_FILE="$SP/sbx/items.json"
  rc=$(export BACKUP_PERMISSIONS=$v; umask 022; run)
  check "'$v' is the same as unset" "$([ "$rc" = 0 ] && [ "$(stat -c %a "$SP"/sbx/out/*-bw-export)" = 755 ]; echo $?)" "rc=$rc"
done

echo "=== T57: BACKUP_PERMISSIONS=private makes every folder 700 and every file 600 ==="
setup ""
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach" BW_ITEMS_FILE="$SP/sbx/items.json"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]},{"id":"i2","name":".ssh","attachments":[{"fileName":"id_ed25519"}]}]' > "$SP/sbx/items.json"
given_modes=$(stat -c %a "$SP/sbx/out" "$SP/sbx/att")
rc=$(export BACKUP_PERMISSIONS=private; umask 022; run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SP/sbx/output")"
check "run folders are 700" "$([ "$(stat -c %a "$SP"/sbx/out/*-bw-export "$SP"/sbx/att/*-bw-export | sort -u)" = 700 ]; echo $?)" "$(run_modes "$SP/sbx")"
check "item folders are 700" "$([ "$(stat -c %a "$SP"/sbx/att/*-bw-export/Doc "$SP"/sbx/att/*-bw-export/.ssh | sort -u)" = 700 ]; echo $?)" "$(run_modes "$SP/sbx/att")"
check "the export and the attachments are 600" "$([ "$(stat -c %a "$SP"/sbx/out/*-bw-export/*.json "$SP"/sbx/att/*-bw-export/Doc/a.pdf "$SP"/sbx/att/*-bw-export/.ssh/id_ed25519 | sort -u)" = 600 ]; echo $?)" "$(run_modes "$SP/sbx")"
check "nothing in a run folder is open to others" "$([ -z "$(open_to_others)" ]; echo $?)" "$(open_to_others)"
check "the folders it was given are left as they were" "$([ "$(stat -c %a "$SP/sbx/out" "$SP/sbx/att")" = "$given_modes" ]; echo $?)" "before: $given_modes; now: $(stat -c %a "$SP/sbx/out" "$SP/sbx/att")"
check "says so" "$(grep -q 'permissions private (BACKUP_PERMISSIONS)' "$SP/sbx/output"; echo $?)" "$(grep 'Folders' "$SP/sbx/output")"
rc=$(export BACKUP_PERMISSIONS=PRIVATE; umask 022; run)
check "the value is case-insensitive" "$([ "$rc" = 0 ] && [ "$(stat -c %a "$SP"/sbx/out/*-bw-export | sort -u | tail -n 1)" = 700 ]; echo $?)" "rc=$rc $(run_modes "$SP/sbx/out")"
# The attachments archive is written by gpg, under its own file creation rules.
setup ""
export BW_REAL_PW=correct-pw BW_ITEMS_FILE="$SP/sbx/items.json"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
rc=$(export BACKUP_PERMISSIONS=private ENCRYPT_ATTACHMENTS=true; umask 022; run)
check "the encrypted archive is 600 too" "$([ "$rc" = 0 ] && [ "$(stat -c %a "$SP"/sbx/att/*-bw-export/attachments.tar.gz.gpg)" = 600 ] && [ -z "$(open_to_others)" ]; echo $?)" "rc=$rc $(run_modes "$SP/sbx/att")"
# Without encryption and without a password, the unencrypted vault is the case that matters most.
setup ""
export BW_REAL_PW=correct-pw EXP=''
rc=$(export BACKUP_PERMISSIONS=private; umask 022; run)
check "an unencrypted export is 600" "$([ "$rc" = 0 ] && [ "$(stat -c %a "$SP"/sbx/out/*-bw-export/export-personal.json)" = 600 ]; echo $?)" "rc=$rc $(run_modes "$SP/sbx/out")"

echo "=== T58: the umask is not the whole story: files a filesystem opens up are closed again ==="
setup ""
mkdir -p "$SP/sbx/aclbw"
# A bw that does what a share with default ACLs does: whatever the umask, what
# an export or a download writes ends up open. Only those commands: the final
# pass runs before the session is closed, and must be what closes them.
cat > "$SP/sbx/aclbw/bw" <<ACL
#!/usr/bin/env bash
"$SP/mock/bw" "\$@"; rc=\$?
case "\$1" in export|get) chmod -R a+rwX "$SP/sbx/out" "$SP/sbx/att" 2>/dev/null ;; esac
exit \$rc
ACL
chmod +x "$SP/sbx/aclbw/bw"
export BW_REAL_PW=correct-pw BW_ITEMS_FILE="$SP/sbx/items.json"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
rc=$(export BACKUP_PERMISSIONS=private; BW_WRAP_DIR="$SP/sbx/aclbw" run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "the run's folders and files are closed again" "$([ -z "$(open_to_others)" ]; echo $?)" "$(open_to_others)"
setup ""
mkdir -p "$SP/sbx/aclbw"
cp "$SP/mock/bw" "$SP/sbx/aclbw/real-bw"
cat > "$SP/sbx/aclbw/bw" <<ACL
#!/usr/bin/env bash
"$SP/mock/bw" "\$@"; rc=\$?
case "\$1" in export|get) chmod -R a+rwX "$SP/sbx/out" "$SP/sbx/att" 2>/dev/null ;; esac
exit \$rc
ACL
chmod +x "$SP/sbx/aclbw/bw"
export BW_REAL_PW=correct-pw
rc=$(export BACKUP_PERMISSIONS=default; BW_WRAP_DIR="$SP/sbx/aclbw" run)
check "left alone when not asked: it stays open" "$([ "$rc" = 0 ] && [ -n "$(open_to_others)" ]; echo $?)" "rc=$rc"

echo "=== T58b: there is no moment when a file is more open than it ends up ==="
setup ""
mkdir -p "$SP/sbx/snapbw"
# A bw that notes, before every call, whatever the run has already written that
# others could read. With the umask there is never any; the final pass alone
# would leave the export open for the whole run.
cat > "$SP/sbx/snapbw/bw" <<SNAP
#!/usr/bin/env bash
find "$SP/sbx/out" "$SP/sbx/att" -mindepth 1 -perm /077 >> "$SP/sbx/exposed"
exec "$SP/mock/bw" "\$@"
SNAP
chmod +x "$SP/sbx/snapbw/bw"; : > "$SP/sbx/exposed"
export BW_REAL_PW=correct-pw BW_ITEMS_FILE="$SP/sbx/items.json"
printf '%s' '[{"id":"i1","name":"Doc","attachments":[{"fileName":"a.pdf"}]}]' > "$SP/sbx/items.json"
rc=$(export BACKUP_PERMISSIONS=private; umask 022; BW_WRAP_DIR="$SP/sbx/snapbw" run)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "nothing was ever readable by others while the run went on" "$([ ! -s "$SP/sbx/exposed" ]; echo $?)" "$(sort -u "$SP/sbx/exposed")"
setup ""; mkdir -p "$SP/sbx/snapbw"
cat > "$SP/sbx/snapbw/bw" <<SNAP
#!/usr/bin/env bash
find "$SP/sbx/out" "$SP/sbx/att" -mindepth 1 -perm /077 >> "$SP/sbx/exposed"
exec "$SP/mock/bw" "\$@"
SNAP
chmod +x "$SP/sbx/snapbw/bw"; : > "$SP/sbx/exposed"
export BW_REAL_PW=correct-pw
rc=$(umask 022; BW_WRAP_DIR="$SP/sbx/snapbw" run)
check "the probe does see an open file when not private" "$([ -s "$SP/sbx/exposed" ]; echo $?)" "probe never fired"

# The run's own two folders, on a share whose default ACLs give new folders
# their mode and ignore the umask: closed straight after they are made.
setup ""
mkdir -p "$SP/sbx/snapbw" "$SP/sbx/aclmk"
cat > "$SP/sbx/snapbw/bw" <<SNAP
#!/usr/bin/env bash
find "$SP/sbx/out" "$SP/sbx/att" -mindepth 1 -perm /077 >> "$SP/sbx/exposed"
exec "$SP/mock/bw" "\$@"
SNAP
cat > "$SP/sbx/aclmk/mkdir" <<MK
#!/usr/bin/env bash
/bin/mkdir "\$@" || exit \$?
# Only the script's own folders (plain mkdir); the mock bw uses "mkdir -p".
case "\$1" in -*) exit 0 ;; esac
for a in "\$@"; do chmod 777 "\$a"; done
MK
chmod +x "$SP/sbx/snapbw/bw" "$SP/sbx/aclmk/mkdir"; : > "$SP/sbx/exposed"
export BW_REAL_PW=correct-pw
rc=$(export BACKUP_PERMISSIONS=private; PATH="$SP/sbx/aclmk:$PATH" BW_WRAP_DIR="$SP/sbx/snapbw" run)
check "the run's folders are closed as soon as they exist" "$([ "$rc" = 0 ] && [ ! -s "$SP/sbx/exposed" ]; echo $?)" "rc=$rc $(sort -u "$SP/sbx/exposed")"
# Two runs in one second share a folder name, and an existing folder is reused.
rm -rf "$SP"/sbx/out/* "$SP"/sbx/att/*
: > "$SP/sbx/exposed"
rc=$(PATH="$SP/sbx/aclmk:$PATH" BW_WRAP_DIR="$SP/sbx/snapbw" run)
check "the shadowed mkdir does open them when not private" "$([ "$rc" = 0 ] && [ -s "$SP/sbx/exposed" ]; echo $?)" "probe never fired"
unset BW_ITEMS_FILE

echo "=== T59: an invalid BACKUP_PERMISSIONS stops before touching the CLI ==="
setup ""
export BW_REAL_PW=correct-pw
for v in 700 public yes true; do
  rc=$(export BACKUP_PERMISSIONS=$v; run)
  check "'$v' is refused" "$([ "$rc" = 1 ] && grep -q "BACKUP_PERMISSIONS must be private or default, not \"$v\"" "$SP/sbx/output" && [ ! -s "$SP/sbx/calls" ]; echo $?)" "rc=$rc $(grep ERROR "$SP/sbx/output")"
done

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


echo "=== T60: same-named items and attachments never overwrite each other ==="
setup ""
# Two items named alike (ignoring case, as NTFS does) shared one folder, and two
# attachments named alike overwrote each other, both counted as saved. Two
# attachments with one name in one item made both downloads fail.
export BW_REAL_PW=correct-pw BW_ATTACHLOG="$SP/sbx/attach"
printf '%s' '[{"id":"aaaaaaaa-1","name":"Passport","attachments":[{"id":"a1aaaaaa-x","fileName":"scan.pdf"}]},
 {"id":"bbbbbbbb-2","name":"passport","attachments":[{"id":"b1bbbbbb-x","fileName":"scan.pdf"}]},
 {"id":"cccccccc-3","name":"Dups","attachments":[{"id":"c1cccccc-x","fileName":"dup.txt"},{"id":"c2cccccc-x","fileName":"dup.txt"},{"id":"c3cccccc-x","fileName":"other"}]},
 {"id":"dddddddd-4","name":"Unique","attachments":[{"id":"d1dddddd-x","fileName":"README"}]}]' > "$SP/sbx/items.json"
export BW_ITEMS_FILE="$SP/sbx/items.json"
rc=$(run)
att=$(compgen -G "$SP/sbx/att/*-bw-export" | head -n 1)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(grep -iE 'error|warning' "$SP/sbx/output")"
check "six files for six attachments" "$([ "$(find "$att" -type f | wc -l)" = 6 ]; echo $?)" "$(cd "$att" && find . -type f)"
check "each item named alike has its own folder" "$([ -f "$att/Passport (aaaaaaaa)/scan.pdf" ] && [ -f "$att/passport (bbbbbbbb)/scan.pdf" ]; echo $?)" "$(cd "$att" && find . -type f)"
check "neither overwrote the other" "$(grep -q 'of item aaaaaaaa-1' "$att/Passport (aaaaaaaa)/scan.pdf" && grep -q 'of item bbbbbbbb-2' "$att/passport (bbbbbbbb)/scan.pdf"; echo $?)" "$(cat "$att"/*/scan.pdf)"
check "attachments named alike in one item are both kept" "$([ -f "$att/Dups/dup (c1cccccc).txt" ] && [ -f "$att/Dups/dup (c2cccccc).txt" ]; echo $?)" "$(cd "$att" && find . -type f)"
check "unique names keep their plain paths" "$([ -f "$att/Dups/other" ] && [ -f "$att/Unique/README" ]; echo $?)" "$(cd "$att" && find . -type f)"
check "every attachment asked for by its ID" "$([ "$(grep -c $'^ATTACHMENT\t' "$SP/sbx/attach")" = 6 ] && ! grep -q 'get attachment scan.pdf\|get attachment dup.txt' "$SP/sbx/calls"; echo $?)" "$(grep '^bw get attachment' "$SP/sbx/calls")"
check "summary counts six" "$(grep -q '^Attachments: 6 saved, 0 failed (unencrypted)$' "$SP/sbx/output"; echo $?)" "$(grep '^Attachments' "$SP/sbx/output")"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
