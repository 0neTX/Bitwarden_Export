# Secret resolution helper shared by bw_export.sh, notify.sh and ping.sh.
# Sourced by those scripts; kept in a file of its own so every caller uses
# the exact same rules and edge-case checks.
# shellcheck shell=bash

# Resolves the secret whose variable NAME is passed as $1.
# - NAME_FILE, when set, is the path of a file holding the value: the
#   convention of the official Docker images (POSTGRES_PASSWORD_FILE, ...). It
#   is always a path, so anything wrong with the file is reported, and NAME
#   must not be set as well.
# - Otherwise NAME itself is used, as before: either the value, or the path of
#   a file holding it.
# - Unset or empty: prints nothing and returns 0.
# - From a file, the value is its first non-empty line, without a trailing \r.
#   An empty, unreadable or non-regular file warns on stderr and prints nothing.
# - Without _FILE, a path under /run/secrets that does not exist is a secret
#   that was not mounted, never a literal value: warns and prints nothing.
#   A value that looks like a file in a folder that exists warns, and is used.
#
# Never prints the secret value itself in any warning or trace.
resolve_secret() {
    set +x
    local name="${1:-}"
    [[ -z "$name" ]] && return 0
    local file_name="${name}_FILE"
    local val="${!name:-}" file="${!file_name:-}"

    if [[ -n "$file" ]]; then
        if [[ -n "$val" ]]; then
            echo -e "${Yellow:-}Warning: $name and $file_name are both set; set only one." >&2
            return 0
        fi
        read_secret_file "$file_name" "$file"
        return 0
    fi

    [[ -z "$val" ]] && return 0

    if [[ -e "$val" ]]; then
        read_secret_file "$name" "$val"
        return 0
    fi

    # Docker mounts secrets there. Used as a literal, the path itself became
    # the password: the export was encrypted with "/run/secrets/..." instead.
    if [[ "$val" == /run/secrets/* ]]; then
        echo -e "${Yellow:-}Warning: $name points to /run/secrets, but that secret is not mounted." >&2
        return 0
    fi

    # A missing file in a folder that exists is most likely a mistake. A literal
    # value that merely starts with '/' (a password, say) has no such folder,
    # and is not warned about on every run.
    local dir="${val%/*}"
    if [[ "$val" == /* && -n "$dir" && -d "$dir" ]]; then
        echo -e "${Yellow:-}Warning: $name looks like a file path, but the file was not found." >&2
    fi

    printf '%s' "$val"
}

# Prints the value held in file $2, which variable $1 points to; warns on
# stderr, naming only the variable, and prints nothing when it cannot.
read_secret_file() {
    local name="$1" path="$2" line="" found=""
    if [[ ! -e "$path" ]]; then
        echo -e "${Yellow:-}Warning: $name points to a file that does not exist." >&2
        return 0
    fi
    if [[ ! -f "$path" ]]; then
        echo -e "${Yellow:-}Warning: $name points to a path that is not a regular file." >&2
        return 0
    fi
    if [[ ! -r "$path" ]]; then
        echo -e "${Yellow:-}Warning: $name points to a file that cannot be read." >&2
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ -n "${line//[[:space:]]/}" ]]; then
            found="$line"
            break
        fi
    done < "$path"
    if [[ -z "$found" ]]; then
        echo -e "${Yellow:-}Warning: $name points to an empty file." >&2
        return 0
    fi
    printf '%s' "$found"
}

# Succeeds when the secret NAME is in use, through NAME or NAME_FILE.
secret_is_set() {
    local name="$1" file_name="${1}_FILE"
    [[ -n "${!name:-}" || -n "${!file_name:-}" ]]
}
