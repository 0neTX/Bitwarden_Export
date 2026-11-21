# Which backup folders a rotation deletes. Sourced by bw_export.sh, and kept in
# a file of its own so tests/run_retention_tests.sh can drive it directly.
# shellcheck shell=bash
#
# Every run writes a folder named <YYYYMMDDHHMMSS>-bw-export. Only names of
# exactly that shape are ever considered, so nothing else in the volume (a
# folder the user made, a file, an item folder inside a backup) can be deleted.

# Parses a KEEP_GFS value such as "7d:4w:6m" or "7d:4w:12m:2y" and prints the
# four counts as "daily weekly monthly yearly". Units may come in any order,
# each at most once, separated by ":" or ","; spaces are ignored. A missing
# unit keeps none of that kind. Returns 1, printing nothing, when the value
# does not have that shape.
gfs_parse() {
    local spec="${1//[[:space:]]/}" token n unit seen="" d=0 w=0 m=0 y=0
    local -a tokens=()
    [[ -n $spec ]] || return 1
    IFS=':,' read -r -a tokens <<<"$spec"
    # A trailing separator ("7d:") leaves no empty field for read, so it is
    # caught here instead.
    [[ $spec == *[:,] ]] && return 1
    for token in "${tokens[@]}"; do
        [[ $token =~ ^([0-9]{1,5})([dwmyDWMY])$ ]] || return 1
        n=$((10#${BASH_REMATCH[1]}))
        unit=${BASH_REMATCH[2],,}
        [[ $seen == *"$unit"* ]] && return 1
        seen+=$unit
        case $unit in
            d) d=$n ;;
            w) w=$n ;;
            m) m=$n ;;
            y) y=$n ;;
        esac
    done
    echo "$d $w $m $y"
}

# Reads backup folder names on stdin, one per line, in any order, and prints
# the ones to delete, oldest first.
#   $1  KEEP_LAST_BACKUPS: keep the N newest (empty: this rule is off)
#   $2  KEEP_GFS: keep the newest backup of each of the last N days, ISO weeks,
#       months and years that have one (empty: this rule is off)
# A folder is kept when any rule keeps it, and the newest folder, which is the
# backup this run just wrote, is always kept. Returns 1, printing nothing, when
# either value is invalid.
backups_to_delete() {
    local keep_last="$1" spec="$2" counts i
    local -a names=() kinds=(d w m y) limits=()
    local -A keep=()

    if [[ -n $keep_last ]]; then
        [[ $keep_last =~ ^[0-9]+$ ]] || return 1
        keep_last=$((10#$keep_last))
    fi
    if [[ -n $spec ]]; then
        counts=$(gfs_parse "$spec") || return 1
        read -r -a limits <<<"$counts"
    fi

    # Newest first. The timestamp prefix sorts the same as the dates it holds.
    mapfile -t names < <(grep -E '^[0-9]{14}-bw-export$' | sort -r -u)
    ((${#names[@]} > 0)) || return 0

    keep[${names[0]}]=1
    if [[ -n $keep_last ]]; then
        for ((i = 0; i < keep_last && i < ${#names[@]}; i++)); do
            keep[${names[i]}]=1
        done
    fi

    if [[ -n $spec ]]; then
        # One "date" for every ISO week at once rather than one per folder.
        local -a weeks=()
        mapfile -t weeks < <(printf '%s\n' "${names[@]}" | cut -c1-8 | date -f - '+%G%V' 2>/dev/null)
        ((${#weeks[@]} == ${#names[@]})) || return 1
        local k kind limit last kept period
        for k in 0 1 2 3; do
            kind=${kinds[k]}
            limit=${limits[k]}
            last=""
            kept=0
            for ((i = 0; i < ${#names[@]} && kept < limit; i++)); do
                case $kind in
                    d) period=${names[i]:0:8} ;;
                    w) period=${weeks[i]} ;;
                    m) period=${names[i]:0:6} ;;
                    y) period=${names[i]:0:4} ;;
                esac
                # Newest first, so the first folder of each period is its newest.
                if [[ $period != "$last" ]]; then
                    keep[${names[i]}]=1
                    last=$period
                    kept=$((kept + 1))
                fi
            done
        done
    fi

    for ((i = ${#names[@]} - 1; i >= 0; i--)); do
        [[ -n ${keep[${names[i]}]:-} ]] || printf '%s\n' "${names[i]}"
    done
    return 0
}
