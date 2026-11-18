# Secret resolution helper shared by bw_export.sh, notify.sh and ping.sh.
# Sourced by those scripts; kept in a file of its own so every caller uses
# the exact same rules and edge-case checks.
# shellcheck shell=bash

# Resolves the variable whose NAME is passed as $1.
# - If unset or empty, prints nothing and returns 0.
# - If its value is an existing regular file, prints the first non-empty line
#   (stripping trailing \r/\n). Warns on stderr and prints nothing if the file
#   is unreadable or empty.
# - Otherwise, prints the literal value. If it starts with '/' and does not
#   exist on disk, warns on stderr that it looks like a missing file path.
#
# Never prints the secret value itself in any warning or trace.
resolve_secret() {
    set +x
    local name="${1:-}"
    [[ -z "$name" ]] && return 0
    [[ -v "$name" ]] || return 0

    local val="${!name}"
    [[ -z "$val" ]] && return 0

    if [[ -f "$val" ]]; then
        if [[ ! -r "$val" ]]; then
            echo -e "${Yellow:-}Warning: $name points to a file that cannot be read." >&2
            return 0
        fi
        local line="" found=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            if [[ -n "${line//[[:space:]]/}" ]]; then
                found="$line"
                break
            fi
        done < "$val"
        if [[ -z "$found" ]]; then
            echo -e "${Yellow:-}Warning: $name points to an empty file." >&2
            return 0
        fi
        printf '%s' "$found"
        return 0
    fi

    if [[ -e "$val" ]]; then
        echo -e "${Yellow:-}Warning: $name points to a path that is not a regular file." >&2
        return 0
    fi

    if [[ "$val" == /* ]]; then
        echo -e "${Yellow:-}Warning: $name starts with '/' and looks like a file path, but the file was not found." >&2
    fi

    printf '%s' "$val"
}
