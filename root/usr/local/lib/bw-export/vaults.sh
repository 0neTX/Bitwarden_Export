#!/usr/bin/env bash
# Exports several vaults in one run (issue #13). bw_export.sh hands over to this
# script when BW_VAULTS is set, and this script runs bw_export.sh once per vault
# with that vault's own environment:
#
#   BW_VAULTS=personal,work
#   VAULT_PERSONAL_BW_CLIENTID=...      VAULT_WORK_BW_URL_SERVER=https://...
#   VAULT_PERSONAL_BW_CLIENTSECRET=...  VAULT_WORK_BW_CLIENTID_FILE=/run/secrets/...
#
# - Credentials and the server belong to each vault and are never inherited.
#   Setting them globally as well is a configuration error.
# - The options below are inherited from the global value unless the vault sets
#   its own, which may be empty to turn an option off for that vault alone.
# - Each vault writes to <OUTPUT_PATH>/<name> and <ATTACHMENTS_PATH>/<name>, and
#   keeps its CLI session in a folder of its own, so two servers never share one.
# - A vault that fails does not stop the others; the run then exits 1.
# - The run ends with one summary covering every vault, which is what the
#   notification carries.
#
#   $1  path of bw_export.sh, the single-vault export to run for each vault
# shellcheck shell=bash

single_script="${1:?usage: vaults.sh <path of bw_export.sh>}"

# shellcheck disable=SC1090
. "${LOG_LIB:-/usr/local/lib/bw-export/log.sh}"

# Each vault's own settings. The secret ones may also come as NAME_FILE.
OWN_SECRETS=(BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD)
OWN_PLAIN=(BW_URL_SERVER)
INHERITED_SECRETS=(EXPORT_PASSWORD)
INHERITED_PLAIN=(BW_ORGANIZATIONS_LIST ENCRYPT_ATTACHMENTS BACKUP_PERMISSIONS KEEP_LAST_BACKUPS KEEP_GFS)

# One vault's part of the run summary, from its own summary block:
#   ✅ work (12s, 1.5MiB)
#      Personal vault: exported (encrypted)
#      Organizations: 2 exported
# Duration and size go on the header; counts that are 0 are left out.
#   $1 icon  $2 folder  $3 status for the header, e.g. "failed with exit 1" (may be empty)
#   stdin: the vault's summary block, without its markers
vault_summary_lines() {
    local icon=$1 folder=$2 status=$3 line key value duration="" size="" header
    local -a body=()
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        key=${line%%: *}
        value=${line#*: }
        case $key in
            Duration) duration=$value; continue ;;
            "Backup size") size=$value; continue ;;
            Organizations | Attachments)
                # "2 exported, 0 skipped, 0 failed" -> "2 exported"
                value=$(sed -E 's/(^|, )0 (exported|skipped|failed|saved)//g; s/^, //' <<<"$value")
                [[ $value == "" || $value == \(* ]] && value="none${value:+ $value}"
                line="$key: $value"
                ;;
        esac
        body+=("$line")
    done
    local -a facts=()
    [[ -n $status ]] && facts+=("$status")
    [[ -n $duration ]] && facts+=("$duration")
    [[ -n $size ]] && facts+=("$size")
    header="$icon $folder"
    if ((${#facts[@]} > 0)); then
        header+=" ($(printf '%s, ' "${facts[@]}"))"
        header=${header/%, )/)}
    fi
    printf '%s\n' "$header"
    ((${#body[@]} > 0)) && printf '   %s\n' "${body[@]}"
    return 0
}

fail_config() {
    log_error "$1"
    shift
    local line
    for line in "$@"; do log_hint "$line"; done
    echo -e "\n----- Summary -----\nVaults: configuration error, nothing exported\n-------------------"
    exit 1
}

is_set() { [[ -n ${!1+x} ]]; }

# --- Vault names --------------------------------------------------------------
names=()
uppers=()
IFS=',' read -r -a raw_names <<<"${BW_VAULTS//[[:space:]]/}"
for name in "${raw_names[@]}"; do
    [[ -z $name ]] && continue
    if ! [[ $name =~ ^[A-Za-z0-9_]+$ ]]; then
        fail_config "Invalid vault name \"$name\" in BW_VAULTS." \
            "Use letters, digits and _ only: the name is part of each vault's variable names (VAULT_<NAME>_...)."
    fi
    upper=${name^^}
    for seen in "${uppers[@]}"; do
        [[ $seen == "$upper" ]] && fail_config "Vault \"$name\" is listed twice in BW_VAULTS (names are not case-sensitive)."
    done
    names+=("$name")
    uppers+=("$upper")
done
((${#names[@]} > 0)) || fail_config "BW_VAULTS is set but names no vault."

# --- One mode at a time -------------------------------------------------------
mixed=()
for var in "${OWN_SECRETS[@]}"; do
    [[ -n ${!var:-} ]] && mixed+=("$var")
    file_var="${var}_FILE"
    [[ -n ${!file_var:-} ]] && mixed+=("$file_var")
done
for var in "${OWN_PLAIN[@]}"; do
    [[ -n ${!var:-} ]] && mixed+=("$var")
done
if ((${#mixed[@]} > 0)); then
    fail_config "BW_VAULTS is set together with ${mixed[*]}." \
        "With BW_VAULTS, each vault's credentials and server go in its own variables, e.g. VAULT_${uppers[0]}_BW_CLIENTID." \
        "Move the single-vault settings into one of the vaults, or remove BW_VAULTS."
fi

# --- Variables that match no vault (typos) --------------------------------------
known_suffixes=()
for var in "${OWN_SECRETS[@]}" "${INHERITED_SECRETS[@]}"; do known_suffixes+=("$var" "${var}_FILE"); done
known_suffixes+=("${OWN_PLAIN[@]}" "${INHERITED_PLAIN[@]}")
while IFS= read -r var; do
    matched=0
    for upper in "${uppers[@]}"; do
        for suffix in "${known_suffixes[@]}"; do
            [[ $var == "VAULT_${upper}_${suffix}" ]] && matched=1 && break 2
        done
    done
    if [[ $matched -eq 0 ]]; then
        log_warn "$var matches no vault in BW_VAULTS and no known setting; it is ignored."
    fi
done < <(compgen -e | grep -E '^VAULT_' || true)

# --- Where each vault's files and CLI session go --------------------------------
base_data="${OUTPUT_PATH:-/var/data}"
base_attachments="${ATTACHMENTS_PATH:-/var/attachments}"
base_appdata="${BITWARDENCLI_APPDATA_DIR:-$(pwd)}"

log_info "Exporting ${#names[@]} vault(s), one after another: ${names[*]}"

# --- Run each vault -------------------------------------------------------------
stop=0
child=""
# The entrypoint signals every process running bw_export.sh, the current vault's
# export included, so here it is enough to let that export finish closing its
# session and not start the next one.
on_signal() {
    stop=$1
    [[ -n $child ]] || exit "$stop"
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT

run_started=$SECONDS
succeeded=0
failed=0
summary_lines=()
index=0
for i in "${!names[@]}"; do
    name=${names[i]}
    upper=${uppers[i]}
    folder=${name,,}
    index=$((index + 1))
    if [[ $stop -ne 0 ]]; then
        summary_lines+=("" "⏹️ $folder: not run, the container was stopped")
        failed=$((failed + 1))
        continue
    fi
    echo
    log_info "===== Vault $index of ${#names[@]}: $folder ====="

    # Inherited options as the vault sees them, to set up its folders.
    perms_var="VAULT_${upper}_BACKUP_PERMISSIONS"
    if is_set "$perms_var"; then perms=${!perms_var}; else perms=${BACKUP_PERMISSIONS:-}; fi
    mode=755
    [[ ${perms,,} == private ]] && mode=700

    vault_data="${base_data%/}/$folder"
    vault_attachments="${base_attachments%/}/$folder"
    vault_appdata="${base_appdata%/}/vaults/$folder"
    setup_error=""
    for dir in "$vault_data" "$vault_attachments"; do
        if [[ ! -d $dir ]] && ! mkdir -m "$mode" "$dir" 2>/dev/null; then
            setup_error="could not create $dir as uid $(id -u)"
            break
        fi
    done
    # Both levels 700: the session folders hold the CLI's tokens.
    for dir in "${base_appdata%/}/vaults" "$vault_appdata"; do
        if [[ -z $setup_error ]] && [[ ! -d $dir ]] && ! mkdir -m 700 "$dir" 2>/dev/null; then
            setup_error="could not create its CLI data folder $dir"
        fi
    done
    if [[ -n $setup_error ]]; then
        log_error "Vault $folder: $setup_error."
        summary_lines+=("" "❌ $folder: $setup_error")
        failed=$((failed + 1))
        continue
    fi

    log=$(mktemp)
    exec {out}> >(tee "$log")
    tee_pid=$!
    (
        unset BW_VAULTS
        for var in "${OWN_SECRETS[@]}" "${OWN_PLAIN[@]}"; do unset "$var"; done
        for var in "${OWN_SECRETS[@]}"; do unset "${var}_FILE"; done
        # Inherited ones: the vault's value replaces the global one, both forms.
        for var in "${INHERITED_SECRETS[@]}"; do
            if is_set "VAULT_${upper}_${var}" || is_set "VAULT_${upper}_${var}_FILE"; then
                unset "$var" "${var}_FILE"
            fi
        done
        for var in "${INHERITED_PLAIN[@]}"; do
            is_set "VAULT_${upper}_${var}" && unset "$var"
        done
        exports=()
        for var in "${OWN_SECRETS[@]}" "${INHERITED_SECRETS[@]}"; do
            src="VAULT_${upper}_${var}"
            is_set "$src" && exports+=("$var=${!src}")
            src="VAULT_${upper}_${var}_FILE"
            is_set "$src" && exports+=("${var}_FILE=${!src}")
        done
        for var in "${OWN_PLAIN[@]}" "${INHERITED_PLAIN[@]}"; do
            src="VAULT_${upper}_${var}"
            is_set "$src" && exports+=("$var=${!src}")
        done
        # The values were copied above, so the source variables can go now:
        # nothing of the other vaults reaches this vault's export.
        while IFS= read -r var; do unset "$var"; done < <(compgen -v | grep -E '^VAULT_')
        export "${exports[@]}" \
            OUTPUT_PATH="$vault_data" ATTACHMENTS_PATH="$vault_attachments" \
            BITWARDENCLI_APPDATA_DIR="$vault_appdata" BW_EXPORT_VAULT="$folder"
        exec bash "$single_script"
    ) >&"$out" 2>&1 &
    child=$!
    wait "$child"
    rc=$?
    # A signal interrupts wait before the export has finished: wait again.
    while kill -0 "$child" 2>/dev/null; do
        wait "$child"
        rc=$?
    done
    child=""
    exec {out}>&-
    wait "$tee_pid" 2>/dev/null

    if [[ $rc -eq 0 ]]; then
        succeeded=$((succeeded + 1))
        icon="✅"; status=""
    else
        failed=$((failed + 1))
        icon="❌"; status="failed with exit $rc"
    fi
    vault_summary=$(sed -n '/^----- Summary -----$/,/^-------------------$/{/^----- Summary -----$/d;/^-------------------$/d;p}' "$log" | tail -n 20)
    summary_lines+=("")
    if [[ -n $vault_summary ]]; then
        while IFS= read -r line; do summary_lines+=("$line"); done < <(vault_summary_lines "$icon" "$folder" "$status" <<<"$vault_summary")
    else
        summary_lines+=("$icon $folder (${status:-stopped early})" "   No summary: the export stopped before writing one. See the log.")
    fi
    rm -f "$log"
done

duration=$((SECONDS - run_started))
if ((duration >= 60)); then duration_text="$((duration / 60))m $((duration % 60))s"; else duration_text="${duration}s"; fi

echo
echo "----- Summary -----"
if [[ $failed -eq 0 ]]; then
    echo "Vaults: all ${#names[@]} exported in $duration_text"
else
    echo "Vaults: $failed of ${#names[@]} failed, $succeeded exported, in $duration_text"
fi
printf '%s\n' "${summary_lines[@]}"
echo "-------------------"

if [[ $stop -ne 0 ]]; then
    exit "$stop"
fi
if [[ $failed -gt 0 ]]; then
    log_error "$failed of ${#names[@]} vault(s) failed."
    exit 1
fi
log_info "All ${#names[@]} vault(s) exported."
