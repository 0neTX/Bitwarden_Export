#!/usr/bin/env bash
# Tests for several vaults in one run (BW_VAULTS, root/usr/local/lib/bw-export/vaults.sh),
# driven through bw_export.sh against the stateful bw mock.
#
#   SCRIPT=$PWD/bw_export.sh bash tests/run_vaults_tests.sh
#
# Assertions read as `check "name" "$([ cond ]; echo $?)" "detail"`; see run_tests.sh.
# shellcheck disable=SC2319
SP="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${SCRIPT:?}"
export SECRETS_LIB="$SP/../root/usr/local/lib/bw-export/secrets.sh"
export RETENTION_LIB="$SP/../root/usr/local/lib/bw-export/retention.sh"
export VAULTS_LIB="$SP/../root/usr/local/lib/bw-export/vaults.sh"
SBX="$SP/sbx-vaults"
pass=0; fail=0

setup() {
  rm -rf "$SBX"; mkdir -p "$SBX/out" "$SBX/att" "$SBX/app" "$SBX/wrap"
  export BW_STATE="$SBX/state" BW_CALLLOG="$SBX/calls" BW_REAL_PW=correct-pw
  : > "$BW_CALLLOG"
}

# Runs bw_export.sh with only the variables given as arguments (NAME=value), on
# top of the paths every test shares. Nothing else from this shell reaches it.
run() {
  env -i PATH="$SBX/wrap:$SP/mock:/usr/local/bin:/usr/bin:/bin" HOME="$SBX" \
      SECRETS_LIB="$SECRETS_LIB" RETENTION_LIB="$RETENTION_LIB" VAULTS_LIB="$VAULTS_LIB" \
      BW_STATE="$BW_STATE" BW_CALLLOG="$BW_CALLLOG" BW_REAL_PW="$BW_REAL_PW" \
      BW_EXPORT_PWLOG="$SBX/pwlog" \
      OUTPUT_PATH="$SBX/out" ATTACHMENTS_PATH="$SBX/att" BITWARDENCLI_APPDATA_DIR="$SBX/app" \
      "$@" bash "$SCRIPT" > "$SBX/output" 2>&1
  echo $?
}

check() { # name, condition-result(0/1), detail
  if [ "$2" = 0 ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  -- $3"; fail=$((fail+1)); fi
}
exported_in() { compgen -G "$SBX/out/$1/*-bw-export/export-personal.json" >/dev/null; }
# The last summary block, as the entrypoint's notification takes it.
summary() {
  awk '/^----- Summary -----$/ { b = ""; i = 1; next } /^-------------------$/ && i { i = 0; l = b; next } i { b = b $0 "\n" } END { printf "%s", l }' "$SBX/output"
}

PERSONAL=(VAULT_PERSONAL_BW_CLIENTID=id-p VAULT_PERSONAL_BW_CLIENTSECRET=secret-p VAULT_PERSONAL_BW_PASSWORD=correct-pw
          VAULT_PERSONAL_BW_URL_SERVER=https://p.example.com)
WORK=(VAULT_WORK_BW_CLIENTID=id-w VAULT_WORK_BW_CLIENTSECRET=secret-w VAULT_WORK_BW_PASSWORD=correct-pw
      VAULT_WORK_BW_URL_SERVER=https://w.example.com)

echo "=== V1: two vaults, each into its own folders with its own key, server and session ==="
setup
rc=$(run BW_VAULTS=personal,work EXPORT_PASSWORD=global-exp "${PERSONAL[@]}" "${WORK[@]}")
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -5 "$SBX/output")"
check "personal exported into out/personal" "$(exported_in personal; echo $?)" "$(find "$SBX/out")"
check "work exported into out/work" "$(exported_in work; echo $?)" "$(find "$SBX/out")"
check "nothing written at the root" "$([ -z "$(compgen -G "$SBX/out/*-bw-export")" ]; echo $?)" "$(ls "$SBX/out")"
check "attachments folders per vault" "$([ -d "$SBX/att/personal" ] && [ -d "$SBX/att/work" ]; echo $?)" "$(ls "$SBX/att")"
check "each vault logged in with its own key, in order" \
  "$([ "$(grep '^APIKEY=' "$SBX/calls" | tr '\n' ' ')" = "APIKEY=id-p:secret-p APIKEY=id-w:secret-w " ]; echo $?)" "$(grep '^APIKEY=' "$SBX/calls")"
check "each vault on its own server" \
  "$(grep -q '^bw config server https://p.example.com' "$SBX/calls" && grep -q '^bw config server https://w.example.com' "$SBX/calls"; echo $?)" "$(grep '^bw config' "$SBX/calls")"
check "each vault in its own CLI session folder" \
  "$(grep -q "APPDATA=\[$SBX/app/vaults/personal\]" "$SBX/calls" && grep -q "APPDATA=\[$SBX/app/vaults/work\]" "$SBX/calls"; echo $?)" "$(grep '^APPDATA' "$SBX/calls" | sort -u)"
check "session folders are 700" "$([ "$(stat -c %a "$SBX/app/vaults/work")" = 700 ]; echo $?)" "$(stat -c %a "$SBX/app/vaults/work")"
check "the global export password reached both" "$([ "$(grep -c $'\tglobal-exp$' "$SBX/pwlog")" = 2 ]; echo $?)" "$(cut -f1 "$SBX/pwlog")"
check "summary counts both" "$(summary | grep -qx 'Vaults: 2 (2 succeeded, 0 failed)'; echo $?)" "$(summary)"
check "summary has each vault's own lines" "$(summary | grep -qx '\[personal\] OK' && summary | grep -qx '  Personal vault: exported (encrypted)'; echo $?)" "$(summary)"

echo "=== V2: a vault that fails does not stop the next one, and the run fails ==="
setup
rc=$(run BW_VAULTS=personal,work EXPORT_PASSWORD=x "${PERSONAL[@]/VAULT_PERSONAL_BW_PASSWORD=correct-pw/VAULT_PERSONAL_BW_PASSWORD=wrong}" "${WORK[@]}")
check "exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
check "personal not exported" "$(! exported_in personal; echo $?)" "$(find "$SBX/out")"
check "work still exported" "$(exported_in work; echo $?)" "$(find "$SBX/out")"
check "summary says which" "$(summary | grep -q '^\[personal\] FAILED' && summary | grep -qx '\[work\] OK' && summary | grep -qx 'Vaults: 2 (1 succeeded, 1 failed)'; echo $?)" "$(summary)"

echo "=== V3: BW_VAULTS with single-vault credentials or server is refused before any export ==="
for extra in BW_CLIENTID=id BW_PASSWORD_FILE=/run/secrets/pw BW_URL_SERVER=https://x.example.com; do
  setup
  rc=$(run BW_VAULTS=personal "${PERSONAL[@]}" "$extra")
  check "[${extra%%=*}] exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
  check "[${extra%%=*}] never logged in" "$(! grep -q '^bw login' "$SBX/calls"; echo $?)" "$(grep '^bw ' "$SBX/calls")"
  check "[${extra%%=*}] names the variable" "$(grep -q "BW_VAULTS is set together with ${extra%%=*}" "$SBX/output"; echo $?)" "$(grep ERROR "$SBX/output")"
done

echo "=== V4: invalid, duplicate and empty vault lists are refused ==="
for list in "my-vault" "personal,PERSONAL" " , "; do
  setup
  rc=$(run "BW_VAULTS=$list" "${PERSONAL[@]}")
  check "[$list] exit 1" "$([ "$rc" = 1 ]; echo $?)" "rc=$rc"
  check "[$list] no CLI call" "$([ ! -s "$SBX/calls" ]; echo $?)" "$(head -3 "$SBX/calls")"
done

echo "=== V5: a vault's EXPORT_PASSWORD replaces the global one, in either form ==="
setup
printf 'work-from-file\n' > "$SBX/work-exp"
rc=$(run BW_VAULTS=personal,work EXPORT_PASSWORD=global-exp "${PERSONAL[@]}" "${WORK[@]}" \
         VAULT_WORK_EXPORT_PASSWORD_FILE="$SBX/work-exp")
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(grep -i 'error' "$SBX/output")"
check "personal used the global one" "$(sed -n 1p "$SBX/pwlog" | grep -qx $'personal\tglobal-exp'; echo $?)" "$(cut -f1 "$SBX/pwlog")"
check "work used its own file" "$(sed -n 2p "$SBX/pwlog" | grep -qx $'personal\twork-from-file'; echo $?)" "$(cut -f1 "$SBX/pwlog")"

echo "=== V6: no vault sees another vault's variables, nor BW_VAULTS ==="
setup
cat > "$SBX/wrap/bw" <<EOF
#!/usr/bin/env bash
env | grep -E '^(VAULT_|BW_VAULTS=)' | cut -d= -f1 >> "$SBX/leaked"
exec "$SP/mock/bw" "\$@"
EOF
chmod +x "$SBX/wrap/bw"
rc=$(run BW_VAULTS=personal,work EXPORT_PASSWORD=x "${PERSONAL[@]}" "${WORK[@]}")
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "no VAULT_* or BW_VAULTS in any CLI call" "$([ ! -s "$SBX/leaked" ]; echo $?)" "$(sort -u "$SBX/leaked")"

echo "=== V7: a VAULT_ variable that matches nothing is reported ==="
setup
rc=$(run BW_VAULTS=personal EXPORT_PASSWORD=x "${PERSONAL[@]}" VAULT_PERSONAL_BW_CLIENTSECRT=typo VAULT_OTHER_BW_CLIENTID=y)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "typo reported" "$(grep -q 'VAULT_PERSONAL_BW_CLIENTSECRT matches no vault' "$SBX/output"; echo $?)" "$(grep -i warning "$SBX/output")"
check "unknown vault reported" "$(grep -q 'VAULT_OTHER_BW_CLIENTID matches no vault' "$SBX/output"; echo $?)" "$(grep -i warning "$SBX/output")"

echo "=== V8: retention per vault; an empty value turns an option off for one vault ==="
setup
mkdir -p "$SBX/out/personal/20200101000000-bw-export" "$SBX/out/work/20200101000000-bw-export"
rc=$(run BW_VAULTS=personal,work EXPORT_PASSWORD=x KEEP_LAST_BACKUPS=1 "${PERSONAL[@]}" "${WORK[@]}" VAULT_WORK_KEEP_LAST_BACKUPS=)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc; $(tail -4 "$SBX/output")"
check "personal rotated its old backup" "$([ ! -d "$SBX/out/personal/20200101000000-bw-export" ]; echo $?)" "$(ls "$SBX/out/personal")"
check "work kept it (option off)" "$([ -d "$SBX/out/work/20200101000000-bw-export" ]; echo $?)" "$(ls "$SBX/out/work")"

echo "=== V9: BW_VAULTS empty is the single-vault mode, unchanged ==="
setup
rc=$(run BW_VAULTS= BW_CLIENTID=id BW_CLIENTSECRET=secret BW_PASSWORD=correct-pw BW_URL_SERVER=https://vw.example.com EXPORT_PASSWORD=x)
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "exported at the root as before" "$(compgen -G "$SBX/out/*-bw-export/export-personal.json" >/dev/null; echo $?)" "$(find "$SBX/out")"
check "no vault summary" "$(! summary | grep -q '^Vaults:'; echo $?)" "$(summary)"

echo "=== V10: BACKUP_PERMISSIONS=private makes each vault's folders 700 ==="
setup
rc=$(run BW_VAULTS=personal EXPORT_PASSWORD=x BACKUP_PERMISSIONS=private "${PERSONAL[@]}")
check "exit 0" "$([ "$rc" = 0 ]; echo $?)" "rc=$rc"
check "out/personal is 700" "$([ "$(stat -c %a "$SBX/out/personal")" = 700 ]; echo $?)" "$(stat -c %a "$SBX/out/personal")"

rm -rf "$SBX"
echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
