#!/usr/bin/env bash
# Tests for root/usr/local/lib/bw-export/retention.sh: which backup folders a
# rotation deletes under KEEP_LAST_BACKUPS and KEEP_GFS. Pure functions, so they
# are driven directly with folder names; nothing is created or deleted.
SP="$(cd "$(dirname "$0")" && pwd)"
RETENTION_LIB="${RETENTION_LIB:-$SP/../root/usr/local/lib/bw-export/retention.sh}"
# shellcheck disable=SC1090
. "$RETENTION_LIB"
pass=0; fail=0

eq() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1  -- expected '$2', got '$3'"; fail=$((fail+1)); fi
}

# Folder names for the given "YYYYMMDD[HHMMSS]" stamps, one per line.
names() {
  local s
  for s in "$@"; do
    [ ${#s} -eq 8 ] && s="${s}030000"
    printf '%s-bw-export\n' "$s"
  done
}
# What backups_to_delete deletes, as the stamps' first 8 or 14 digits, on one line.
deleted() { # keep_last, gfs, stamps...
  local keep_last="$1" gfs="$2"
  shift 2
  names "$@" | backups_to_delete "$keep_last" "$gfs" | sed 's/-bw-export$//; s/030000$//' | paste -sd' ' -
}
# The status and output of an invalid call, on one line.
refused() { # keep_last, gfs
  local out rc
  out=$(names 20240101 20240102 | backups_to_delete "$1" "$2"); rc=$?
  echo "rc=$rc out=[$out]"
}

echo "=== R1: KEEP_GFS values that parse ==="
eq "days, weeks, months"     "7 4 6 0"   "$(gfs_parse 7d:4w:6m)"
eq "any order, comma"        "0 0 12 2"  "$(gfs_parse 2y,12m)"
eq "spaces ignored"          "7 4 0 0"   "$(gfs_parse ' 7d : 4w ')"
eq "upper case"              "7 0 0 1"   "$(gfs_parse 7D:1Y)"
eq "leading zero is decimal" "8 0 0 0"   "$(gfs_parse 08d)"
eq "zero is allowed"         "0 0 0 0"   "$(gfs_parse 0d)"

echo "=== R2: KEEP_GFS values that do not ==="
for bad in "" "7" "7x" "d" "7d:" ":7d" "7d::4w" "7d:7d" "-1d" "1.5d" "7days" "7d 4w" "999999d"; do
  out=$(gfs_parse "$bad"); rc=$?
  eq "rejects '$bad'" "rc=1 out=[]" "rc=$rc out=[$out]"
done

echo "=== R3: KEEP_LAST_BACKUPS alone behaves as it always did ==="
eq "keeps the 3 newest"      "20240101 20240102" "$(deleted 3 '' 20240104 20240101 20240105 20240103 20240102)"
eq "fewer than N: none"      ""                  "$(deleted 9 '' 20240101 20240102)"
eq "exactly N: none"         ""                  "$(deleted 2 '' 20240101 20240102)"
eq "leading zero is decimal" "20240101"          "$(deleted 08 '' 20240101 20240102 20240103 20240104 20240105 20240106 20240107 20240108 20240109)"

echo "=== R4: the backup just written is never deleted ==="
eq "KEEP_LAST_BACKUPS=0 keeps the newest" "20240101 20240102" "$(deleted 0 '' 20240101 20240102 20240103)"
eq "KEEP_GFS=0d keeps the newest"         "20240101 20240102" "$(deleted '' 0d 20240101 20240102 20240103)"

echo "=== R5: daily keeps the newest backup of each of the last N days ==="
eq "two runs a day: the later one stays" "20240103080000 20240104080000" \
  "$(deleted '' 2d 20240103080000 20240103200000 20240104080000 20240104200000)"
eq "gaps are not counted as days" "20240101" "$(deleted '' 3d 20240101 20240110 20240120 20240130)"

echo "=== R6: weekly uses ISO weeks, across the turn of the year ==="
# 2020-12-28 to 2021-01-03 is ISO week 2020-W53; 2021-01-04 starts 2021-W01.
eq "one week spanning two years" "20201228 20201231" \
  "$(deleted '' 2w 20201228 20201231 20210103 20210104)"
eq "Sunday and Monday are different weeks" "" "$(deleted '' 2w 20240107 20240108)"

echo "=== R7: monthly and yearly ==="
eq "monthly keeps each month's newest" "20240101 20240115 20240131 20240201 20240301" \
  "$(deleted '' 2m 20240101 20240115 20240131 20240201 20240229 20240301 20240331)"
eq "yearly keeps each year's newest" "20220101 20221231 20230101" \
  "$(deleted '' 2y 20220101 20221231 20230101 20231231 20240601)"

echo "=== R8: a typical daily schedule, 7d:4w:6m ==="
# One backup a day at 03:00 from 2024-01-01 to 2024-06-30.
stamps=()
for i in $(seq 0 181); do stamps+=("$(date -d "2024-01-01 +$i day" +%Y%m%d)"); done
kept=$(names "${stamps[@]}" | backups_to_delete '' 7d:4w:6m)
kept=$(comm -23 <(names "${stamps[@]}" | sort) <(printf '%s\n' "$kept" | sort) | sed 's/030000-bw-export$//' | paste -sd' ' -)
# 7 days (24-30 Jun), the Sundays ending the last 4 ISO weeks (9, 16, 23 Jun;
# the 30th is already kept) and the last day of the last 6 months.
eq "kept set" "20240131 20240229 20240331 20240430 20240531 20240609 20240616 20240623 20240624 20240625 20240626 20240627 20240628 20240629 20240630" "$kept"

echo "=== R9: KEEP_LAST_BACKUPS and KEEP_GFS together keep the union ==="
eq "last 2 plus one per month" "20240101 20240201" \
  "$(deleted 2 2m 20240101 20240102 20240201 20240202 20240203)"

echo "=== R10: only <14 digits>-bw-export folders are ever candidates ==="
out=$(printf '%s\n' notes-bw-export 2024-bw-export 20240101000000-bw-export.bak \
        x20240101000000-bw-export 20240101000000-bw-export 20240102000000-bw-export \
      | backups_to_delete 1 '')
eq "deletes only the old backup" "20240101000000-bw-export" "$out"
eq "no input, no output, success" "rc=0 out=[]" "$(out=$(backups_to_delete 1 7d </dev/null); echo "rc=$? out=[$out]")"

echo "=== R11: invalid settings delete nothing ==="
eq "KEEP_LAST_BACKUPS not a number" "rc=1 out=[]" "$(refused abc '')"
eq "KEEP_LAST_BACKUPS negative"     "rc=1 out=[]" "$(refused -1 '')"
eq "KEEP_GFS invalid"               "rc=1 out=[]" "$(refused '' 7x)"
eq "both set, one invalid"          "rc=1 out=[]" "$(refused 1 7d:)"
eq "an impossible date"             "rc=1 out=[]" "$(names 20240231 20240101 | backups_to_delete '' 1w >/dev/null; echo "rc=$? out=[]")"

echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
