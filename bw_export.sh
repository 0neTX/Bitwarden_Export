#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155

#  _                                             _
# | |____      __      _____  ___ __   ___  _ __| |_
# | '_ \ \ /\ / /____ / _ \ \/ / '_ \ / _ \| '__| __|
# | |_) \ V  V /_____|  __/>  <| |_) | (_) | |  | |_
# |_.__/ \_/\_/       \___/_/\_\ .__/ \___/|_|   \__|
#                              |_|
# Bitwarden CLI Vault Export Script
# Author: 0netx based on David H (@dh024)
#
# This script will backup the following:
#   - personal vault contents, password encrypted (or unencrypted)
#   - organizational vault contents (passwd encrypted or unencrypted)
#   - file attachments
# It will also report on whether there were items in the Trash that
# could not be exported.

# Constant and global variables
# Where the CLI keeps data.json (account, tokens, cached profile). Must be
# exported or the CLI never sees it and silently falls back to its own default.
export BITWARDENCLI_APPDATA_DIR="${BITWARDENCLI_APPDATA_DIR:-"$(pwd)"}"
params_validated=0

# log_info, log_warn, log_error, log_hint: see log.sh. Overridable like the
# other libraries below, so the tests can point it at the repository.
LOG_LIB="${LOG_LIB:-/usr/local/lib/bw-export/log.sh}"
# shellcheck disable=SC1090
if ! . "$LOG_LIB"; then
    echo "$(date '+%F %T') ERROR: Could not load $LOG_LIB."
    exit 1
fi

# Several vaults (BW_VAULTS): vaults.sh runs this script once per vault, with
# BW_VAULTS removed, so each of those runs is an ordinary single-vault export.
# Checked here rather than in the entrypoint because Infisical may be what
# provides BW_VAULTS, and it only does so when this script starts.
if [[ -n "${BW_VAULTS:-}" ]]; then
    exec bash "${VAULTS_LIB:-/usr/local/lib/bw-export/vaults.sh}" "$0"
fi

# Overridable like entrypoint.sh's PING_LIB and NOTIFY_LIB, so the tests can
# point it at the repository. Without it no credential can be read at all.
SECRETS_LIB="${SECRETS_LIB:-/usr/local/lib/bw-export/secrets.sh}"
# shellcheck disable=SC1090
if ! . "$SECRETS_LIB"; then
    log_error "Could not load $SECRETS_LIB, exiting..."
    exit 1
fi

# For the run summary at the end.
run_started=$SECONDS

# Which old backups a rotation deletes (KEEP_LAST_BACKUPS, KEEP_GFS).
RETENTION_LIB="${RETENTION_LIB:-/usr/local/lib/bw-export/retention.sh}"
# shellcheck disable=SC1090,SC1091
if ! . "$RETENTION_LIB"; then
    log_error "Could not load $RETENTION_LIB."
    exit 1
fi

#Set locations to save export files
if [[ -z "${OUTPUT_PATH}" ]]; then
    save_folder="/var/data/"
else
    save_folder="${OUTPUT_PATH}"
    if [[ ! -d "$save_folder" ]]; then
        log_error "Could not find the folder in which to save the files: $save_folder"
        params_validated=-1
    fi
fi

# True when $1 is backed by an anonymous volume: what Docker and Podman create
# for a VOLUME nobody bound. mountinfo's fourth field is the source path, which
# for an anonymous volume ends in volumes/<64 hex id>/_data; a bind mount or a
# named volume shows its own path or name there instead.
#   $2  mountinfo file, /proc/self/mountinfo unless a test points elsewhere
is_anonymous_volume() {
    awk -v mp="$1" '$5 == mp { print $4 }' "${2:-/proc/self/mountinfo}" 2>/dev/null \
        | grep -Eq '/volumes/[0-9a-f]{64}/_data$'
}

#Set locations to save attachment files
if [[ -z "${ATTACHMENTS_PATH}" ]]; then
    save_folder_attachments="/var/attachments/"
    # The README and docker-compose.yml used to mount /var/attachment (singular),
    # which nothing here writes to: attachments went to the anonymous volume
    # behind VOLUME /var/attachments and never reached the host. Honour such a
    # mount rather than keep losing them until the compose file is updated.
    #
    # Only when /var/attachments is that anonymous volume, though. VOLUME makes it
    # a mount point either way, so being mounted says nothing; but someone who
    # bound both paths to different folders already has attachments landing in
    # the right one, and must not have them moved.
    if mountpoint -q /var/attachment 2>/dev/null \
            && { ! mountpoint -q /var/attachments 2>/dev/null || is_anonymous_volume /var/attachments; }; then
        save_folder_attachments="/var/attachment/"
        log_warn "/var/attachment is mounted. Saving attachments there."
        log_hint "Mount the host folder on /var/attachments instead; /var/attachment will stop being used in a future release."
    fi
else
    save_folder_attachments="${ATTACHMENTS_PATH}"
    if [[ ! -d "$save_folder_attachments" ]]; then
        log_error "Could not find the folder in which to save the attachments files: $save_folder_attachments"
        params_validated=-1
    fi
fi

# A folder this user cannot write to fails every export with an error from the
# CLI that does not name the cause. Running as a non-root user (compose
# "user:"), the host folder's owner is the usual reason.
for folder in "$save_folder" "$save_folder_attachments"; do
    if [[ -d "$folder" ]] && [[ ! -w "$folder" ]]; then
        log_error "Cannot write to $folder as uid $(id -u)."
        log_info "Give that user write access to the host folder mounted there, e.g. chown $(id -u):$(id -g) <folder>."
        params_validated=-1
    fi
done

#Set Vaultwarden own server.
# To obtain your organization_id value, open a terminal and type:
#   bw login #(follow the prompts);
bw_url_server="${BW_URL_SERVER:-}"

#Set Bitwarden session authentication.
# To obtain your organization_id value, open a terminal and type:
#   bw login #(follow the prompts);
if ! secret_is_set BW_CLIENTID; then
    log_error "Neither BW_CLIENTID nor BW_CLIENTID_FILE is set."
    log_hint "It comes from your personal API key: https://bitwarden.com/help/personal-api-key/"
    params_validated=-1
else
    client_id=$(resolve_secret BW_CLIENTID)
    if [[ -z "$client_id" ]]; then
        log_error "BW_CLIENTID is set, but no value could be read from it."
        params_validated=-1
    fi
fi

if ! secret_is_set BW_CLIENTSECRET; then
    log_error "Neither BW_CLIENTSECRET nor BW_CLIENTSECRET_FILE is set."
    log_hint "It comes from your personal API key: https://bitwarden.com/help/personal-api-key/"
    params_validated=-1
else
    client_secret=$(resolve_secret BW_CLIENTSECRET)
    if [[ -z "$client_secret" ]]; then
        log_error "BW_CLIENTSECRET is set, but no value could be read from it."
        params_validated=-1
    fi
fi

if ! secret_is_set BW_PASSWORD; then
    log_error "Neither BW_PASSWORD nor BW_PASSWORD_FILE is set."
    params_validated=-1
else
    bw_password=$(resolve_secret BW_PASSWORD)
    if [[ -z "$bw_password" ]]; then
        log_error "BW_PASSWORD is set, but no value could be read from it."
        params_validated=-1
    fi
fi

#Set Organization ID (if applicable)
# "none", in any case and with any spacing, exports no organization at all.
organization_list="${BW_ORGANIZATIONS_LIST}"
organizations_none=0
organizations_setting=${BW_ORGANIZATIONS_LIST//[[:space:]]/}
if [[ ${organizations_setting,,} == none ]]; then
    organizations_none=1
    organization_list=""
    log_info "BW_ORGANIZATIONS_LIST is none. No organization will be exported."
fi

#Check export password
if ! secret_is_set EXPORT_PASSWORD; then
    log_warn "EXPORT_PASSWORD is not set, so the vault is exported UNENCRYPTED."
    log_hint "Set EXPORT_PASSWORD, and keep it somewhere other than Bitwarden itself."
    password1=""
else
    password1=$(resolve_secret EXPORT_PASSWORD)
    if [[ -z "$password1" ]]; then
        # Set means an encrypted export was asked for. Falling back to a plain
        # one wrote the whole vault to disk unencrypted and reported success,
        # for instance when Docker had made a folder of a missing secret file.
        log_error "EXPORT_PASSWORD is set, but no password could be read from it."
        log_hint "The vault is not exported unencrypted in its place."
        params_validated=-1
    fi
fi

# Attachments are saved as plain files unless ENCRYPT_ATTACHMENTS is on. Then
# they are packed into one archive encrypted with EXPORT_PASSWORD, and are never
# written in the clear to the attachments volume. Without a password there is
# nothing to encrypt with, so the run stops here rather than fall back to plain
# files the user asked not to have.
attachments_encryption=0
case "${ENCRYPT_ATTACHMENTS,,}" in
    "" | false | no | off | 0) ;;
    true | yes | on | 1)
        if [[ -z $password1 ]]; then
            log_error "ENCRYPT_ATTACHMENTS is on, but EXPORT_PASSWORD is not set. The attachments are encrypted with it."
            params_validated=-1
        elif ! command -v gpg >/dev/null 2>&1; then
            log_error "ENCRYPT_ATTACHMENTS is on, but gpg is not installed."
            params_validated=-1
        else
            attachments_encryption=1
        fi
        ;;
    *)
        log_error "ENCRYPT_ATTACHMENTS must be true or false, not \"${ENCRYPT_ATTACHMENTS}\"."
        params_validated=-1
        ;;
esac

# Who can read what a run writes. The CLI already saves its files as 600 and
# the folder of each vault item as 700. What the container creates itself takes
# its umask, normally 022: each run's folder is 755 (anyone can list the item
# names and file names in it) and the encrypted attachments archive 644.
# BACKUP_PERMISSIONS=private makes them 700 and 600, so only their owner can
# read them. Off by default, because it takes access away from anyone who lists
# or copies the backups as another user (a NAS share, a backup tool).
backup_private=0
case "${BACKUP_PERMISSIONS,,}" in
    "" | default) ;;
    private)
        backup_private=1
        ;;
    *)
        log_error "BACKUP_PERMISSIONS must be private or default, not \"${BACKUP_PERMISSIONS}\"."
        params_validated=-1
        ;;
esac

# Check if required parameters has beed proviced.
if [[ $params_validated != 0 ]]; then
    log_error "The configuration is not valid, so nothing was exported. See the errors above."
    exit 1
fi

# What this run is about to do, for whoever reads the log later: every setting
# that changes the outcome, and where each credential comes from. No value of a
# secret, and no server address (see server_label in log.sh).
[[ -n ${BW_EXPORT_VAULT:-} ]] && log_info "Vault: $BW_EXPORT_VAULT"
log_info "Server: $(server_label "$bw_url_server")"
log_info "Credentials: BW_CLIENTID $(secret_source BW_CLIENTID), BW_CLIENTSECRET $(secret_source BW_CLIENTSECRET), BW_PASSWORD $(secret_source BW_PASSWORD)"
if [[ -n $password1 ]]; then
    log_info "Vault export: encrypted with EXPORT_PASSWORD ($(secret_source EXPORT_PASSWORD))"
else
    log_info "Vault export: UNENCRYPTED"
fi
if [[ $organizations_none -eq 1 ]]; then
    log_info "Organizations: none (BW_ORGANIZATIONS_LIST=none)"
elif [[ -n $organization_list ]]; then
    log_info "Organizations: the $(tr ',' '\n' <<<"$organization_list" | grep -c .) listed in BW_ORGANIZATIONS_LIST"
else
    log_info "Organizations: every one you own or administer"
fi
if [[ $attachments_encryption -eq 1 ]]; then
    log_info "Attachments: one archive encrypted with EXPORT_PASSWORD (ENCRYPT_ATTACHMENTS)"
else
    log_info "Attachments: plain files"
fi
log_info "Folders: exports in $save_folder, attachments in $save_folder_attachments, permissions $([[ $backup_private -eq 1 ]] && echo "private (BACKUP_PERMISSIONS)" || echo default)"
retention_text=""
[[ -n ${KEEP_LAST_BACKUPS} ]] && retention_text="last ${KEEP_LAST_BACKUPS} (KEEP_LAST_BACKUPS)"
[[ -n ${KEEP_GFS} ]] && retention_text="${retention_text:+$retention_text and }${KEEP_GFS} (KEEP_GFS)"
log_info "Retention: ${retention_text:-off, every backup is kept}"

session_closed=0

# From here on, nothing this run writes is readable by anyone else. Set before
# the CLI creates anything, so there is no moment when a file is more open than
# it ends up. mkdir and gpg honour it; the CLI's own modes are already stricter.
if [[ $backup_private -eq 1 ]]; then
    umask 077
fi

# Close the Bitwarden CLI session and wipe the credentials from the environment.
# Idempotent: safe to call explicitly and from the EXIT trap.
close_session() {
    # Plain attachments waiting to be encrypted never outlive the run, however
    # it ends. Outside the guard: the explicit call below comes first.
    if [[ -n ${attachments_staging:-} ]]; then
        rm -rf "$attachments_staging"
        attachments_staging=""
    fi
    if [[ $session_closed -ne 0 ]]; then
        return 0
    fi
    session_closed=1
    log_info "Closing Bitwarden CLI session..."
    bw lock >/dev/null 2>&1 || true
    bw logout >/dev/null 2>&1 || true
    BW_CLIENTID=
    BW_CLIENTSECRET=
    BW_SESSION=
}

log_info "Starting the export."

# bw login --apikey reads them from the environment. Exported explicitly: given
# through BW_CLIENTID_FILE, they were never in the environment to begin with.
export BW_CLIENTID="$client_id" BW_CLIENTSECRET="$client_secret"

# From here on the CLI holds state, so never leave a session behind: a leftover
# session makes every later run fail at "bw config server" and at "bw unlock".
# A bare EXIT trap is not enough, it does not run when the container is stopped.
trap close_session EXIT
trap 'close_session; exit 130' INT
trap 'close_session; exit 143' TERM

# Always start from a clean state. Credentials cached by a previous run go stale
# whenever the server changes them (a server upgrade, a KDF or master password
# change), and "bw unlock" validates the password against that cached copy, so a
# stale cache fails forever until the account is logged out and logged in again.
if [[ $(bw status | jq -r .status) != "unauthenticated" ]]; then
    log_info "Existing session detected. Logging out before starting..."
    bw logout >/dev/null 2>&1 || true
    if [[ $(bw status | jq -r .status) != "unauthenticated" ]]; then
        log_error "Could not log out the previous session."
        log_info "Remove the Bitwarden CLI data directory or recreate the container, then retry."
        exit 1
    fi
fi

if [[ $bw_url_server != "" && $bw_url_server != *"bitwarden.com" ]]; then
    log_info "Setting custom server..."
    if ! bw config server "$bw_url_server" --nointeraction >/dev/null; then
        log_error "Failed to set the server URL (BW_URL_SERVER)."
        log_hint "It must be the full HTTPS address of your server, e.g. https://vault.example.com."
        exit 1
    fi
fi

# What the CLI printed on stderr, under the error it explains, one indented
# line each. The CLI's last message often lacks a newline, so printed as it
# came, the next log line ran into it. Its messages describe the failure
# (wrong password, unreachable server), never a credential.
#   $1  file holding the CLI's stderr
cli_said() {
    [[ -s $1 ]] || return 0
    { cat "$1"; echo; } | grep -v '^[[:space:]]*$' | sed 's/^/    bw: /'
}

log_info "Performing login..."
cli_err=$(mktemp)
bw login --apikey --method 0 --quiet --nointeraction 2>"$cli_err"
if [[ $(bw status | jq -r .status) == "unauthenticated" ]]; then
    log_error "Failed to login."
    cli_said "$cli_err"
    rm -f "$cli_err"
    log_hint "Check BW_CLIENTID and BW_CLIENTSECRET, and that they belong to an account on this server."
    exit 1
fi

#Unlock the vault
log_info "Unlocking the vault..."
# Neither password goes on a command line: any user on the host can read a
# container process's arguments with ps, but only its owner and root can read its
# environment or its stdin. A dedicated variable rather than BW_PASSWORD, which
# may hold a file path instead of the password.
session_key=$(BW_EXPORT_UNLOCK_PASSWORD="$bw_password" bw unlock --passwordenv BW_EXPORT_UNLOCK_PASSWORD --raw 2>"$cli_err")
unlock_result=$?
#Verify that unlock succeeded
if [[ $unlock_result -ne 0 ]] || [[ -z $session_key ]]; then
    log_error "Failed to unlock vault with BW_PASSWORD."
    cli_said "$cli_err"
    rm -f "$cli_err"
    log_hint "Check BW_PASSWORD. On a self-hosted Vaultwarden older than 1.37.4 this error appears even with the right password: see the Server line above."
    exit 1
else
    log_info "Vault unlocked."
fi
rm -f "$cli_err"
#Export the session key as an env variable (needed by BW CLI)
export BW_SESSION="$session_key"

#Check if the user has decided to enter a password or save unencrypted
log_info "Performing vault exports..."

# 1. Export the personal vault
if [[ ! -d "$save_folder" ]]; then
    log_error "Could not find the folder in which to save the files. Path: $save_folder"
    exit 1
fi

working_folder=$(date '+%Y%m%d%H%M%S')-bw-export

runtime_save_folder=$save_folder/$working_folder/
runtime_save_folder_attachments=$save_folder_attachments/$working_folder/

if [[ ! -d "$runtime_save_folder" ]]; then
    mkdir "$runtime_save_folder"
fi
# Explicit as well as the umask: a folder with default ACLs, as many NAS shares
# have, gives new files the ACL's mode and ignores the umask.
if [[ $backup_private -eq 1 ]]; then
    chmod 700 "$runtime_save_folder" 2>/dev/null
fi

if [[ ! -d "$runtime_save_folder_attachments" ]]; then
    mkdir "$runtime_save_folder_attachments"
fi
if [[ $backup_private -eq 1 ]]; then
    chmod 700 "$runtime_save_folder_attachments" 2>/dev/null
fi

# Every export is checked: the CLI reports a failure (an unwritable folder, a
# rejected organization) only through its exit status and a line on stderr, and
# without this the run went on to say "Vault export complete." and exit 0 with
# no vault file written at all.
exports_failed=0
# A listing the CLI refuses (a session dropped after a 401, for one) is not an
# empty vault: without this it read as "No organizational vault exists" or "No
# attachments exist", and the run skipped that part of the backup in silence.
listings_failed=0
# $1: what is being exported, for the log. The rest: the bw export arguments.
# With a password, --password goes last and with no value: the CLI then prompts
# for it and reads the answer from stdin. The prompt is redrawn once per
# character, which would put the password's length in the log, so it is dropped.
# The CLI exits 0 without writing anything if that read comes back empty, so the
# file it reports as saved is checked too.
run_export() {
    local what="$1" saved rc=0 errlog
    shift
    if [[ -n "$password1" ]]; then
        errlog=$(mktemp)
        saved=$(printf '%s\n' "$password1" | bw export "$@" --password 2>"$errlog") || rc=$?
        grep -v 'Export file password' "$errlog" >&2
        rm -f "$errlog"
    else
        saved=$(bw export "$@") || rc=$?
    fi
    [[ -n "$saved" ]] && log_info "$saved"
    if [[ $rc -eq 0 ]] && [[ ! -s "$(sed -n 's/^Saved //p' <<<"$saved" | tail -n 1)" ]]; then
        rc=1
        log_error "The CLI reported no saved file for the $what."
    fi
    if [[ $rc -ne 0 ]]; then
        exports_failed=$((exports_failed + 1))
        log_error "Failed to export the $what."
    fi
}

if [[ $password1 == "" ]]; then
    log_info "Exporting personal vault to an unencrypted file..."
    run_export "personal vault" --format json --output "$runtime_save_folder"
else
    log_info "Exporting personal vault to a password-encrypted file..."
    run_export "personal vault" --format encrypted_json --output "$runtime_save_folder"
fi
personal_exported=$((exports_failed == 0))

# True when every argument is 0: for checking each command of a pipeline.
all_zero() {
    local status
    for status in "$@"; do
        [[ $status -eq 0 ]] || return 1
    done
}

# Packs the folder $1 into the archive $2, encrypted with EXPORT_PASSWORD, then
# decrypts it again to prove it can be restored. gpg's own symmetric format, so
# "gpg -d" restores it on any system. The password goes through a pipe on fd 3,
# never on a command line, and gpg gets a keyring of its own that is thrown away.
# The archive is written under a .part name and renamed once verified, so a run
# stopped halfway never leaves a truncated archive that looks like a good one.
encrypt_folder() {
    local src="$1" archive="$2" part="$2.part" gpg_home rc=0
    local -a gpg_args
    gpg_home=$(mktemp -d) || return 1
    gpg_args=(--homedir "$gpg_home" --batch --quiet --no-tty --yes
        --pinentry-mode loopback --passphrase-fd 3)
    # The folder's entries rather than "." itself: an archive holding "./"
    # would reset the permissions of whatever folder it is restored into.
    find "$src" -mindepth 1 -maxdepth 1 -printf '%P\0' |
        tar -C "$src" --null -T - -czf - |
        gpg "${gpg_args[@]}" --symmetric --cipher-algo AES256 --compress-algo none \
            --output "$part" 3< <(printf '%s' "$password1")
    all_zero "${PIPESTATUS[@]}" || rc=1
    if [[ $rc -eq 0 ]]; then
        gpg "${gpg_args[@]}" --decrypt "$part" 3< <(printf '%s' "$password1") | tar -tzf - >/dev/null
        all_zero "${PIPESTATUS[@]}" || rc=1
    fi
    [[ $rc -eq 0 ]] && { mv -f "$part" "$archive" || rc=1; }
    # gpg starts an agent for that keyring; stop it rather than leave it behind.
    gpgconf --homedir "$gpg_home" --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf "$gpg_home"
    rm -f "$part"
    return "$rc"
}

# 2. Download all attachments (file backup)
# Item and file names are attacker-controlled: anyone who can put an item in a
# shared organization collection chooses them. They are therefore passed to the
# CLI as arguments and never interpolated into shell text.
#
# The item name also becomes a directory name, so it is reduced to something
# every target filesystem accepts: "/" and "\" would be read as path
# separators, and NTFS (this image is commonly bind-mounted onto Windows
# volumes) rejects < > : " | ? * and trailing dots or spaces outright.
#
# Names are not unique, paths must be. Two items with the same name would share
# a folder, and two attachments with the same name, in one item or in two items
# sharing a folder, would overwrite each other while both were counted as
# saved. So every item whose folder name is taken by another gets its short ID
# appended, "Passport (1a2b3c4d)", and so does every attachment whose name is
# taken within its item, "scan (9f8e7d6c).pdf". Names are compared ignoring
# case, as NTFS and macOS do. Unique names keep the plain form they always had.
# Each attachment is asked for by its ID, not its name: by name the CLI matches
# substrings, and two attachments with one name made both downloads fail.
attachments_failed=0
attachments_saved=0
archive_failed=0
items_listed=1
if ! items_json=$(bw list items); then
    listings_failed=$((listings_failed + 1))
    items_listed=0
    items_json='[]'
    log_error "Could not list the vault items, so no attachments were saved."
fi
# An item without attachments carries an empty array, not null, so counting the
# attachments themselves is the only way to tell whether there is work to do.
attachments_total=$(jq '[.[] | (.attachments // [])[]] | length' <<<"$items_json")
if [[ $attachments_total -gt 0 ]]; then
    log_info "Saving $attachments_total attachment(s) from $(jq '[.[] | select((.attachments // []) | length > 0)] | length' <<<"$items_json") item(s)..."
    # To be encrypted, they are downloaded to a private folder inside the
    # container first, so no plain copy ever reaches the attachments volume (or
    # a snapshot of it). close_session removes that folder.
    attachments_target=$runtime_save_folder_attachments
    if [[ $attachments_encryption -eq 1 ]]; then
        if ! attachments_staging=$(mktemp -d "${TMPDIR:-/tmp}/bw-export-attachments.XXXXXX"); then
            attachments_staging=""
            log_error "Could not create a temporary folder for the attachments."
            exit 1
        fi
        attachments_target=$attachments_staging/
    fi
    # The loop runs in this shell (process substitution, not a pipe), so the
    # count survives it. A failed download is only reported by the CLI's exit
    # status; on stdout it looks much like a successful one.
    # The CLI's "Saved <path>" is not logged: the path holds the item's name and
    # the file's name, which are vault data (a person's name, an ID number). A
    # failure is logged with the item's ID and the attachment's position, which
    # is enough to find it in the vault without naming it.
    attachment_index=0
    attachment_err=$(mktemp)
    while IFS=$'\t' read -r item_id attachment_ref output_path; do
        attachment_index=$((attachment_index + 1))
        rc=0
        bw get attachment "$attachment_ref" --itemid "$item_id" --output "$output_path" >/dev/null 2>"$attachment_err" || rc=$?
        if [[ $rc -ne 0 ]]; then
            attachments_failed=$((attachments_failed + 1))
            log_warn "Attachment $attachment_index of $attachments_total (item $item_id) could not be saved."
            cli_said "$attachment_err"
        else
            attachments_saved=$((attachments_saved + 1))
        fi
    done < <(jq -r --arg dir "$attachments_target" '
        def folder_name: (. // "")
            | gsub("[/<>:\"\\\\|?*[:cntrl:]]"; "_")
            | sub(" +$"; "") | sub("\\.+$"; "")
            | if . == "" then "unnamed" else . end;
        def base_name: (. // "") | split("/") | last // "";
        def short_id: (. // "") | .[0:8];
        def with_id($id): (capture("^(?<stem>.+?)(?<ext>\\.[^.]*)?$") // {stem: ., ext: ""})
            | "\(.stem) (\($id | short_id))\(.ext // "")";
        [ .[] | select((.attachments // []) | length > 0)
          | . + {folder: (.name | folder_name)} ] as $items
        | ($items | group_by(.folder | ascii_downcase) | map(select(length > 1) | .[].id)) as $shared
        | $items[] | . as $item
        | (if any($shared[]; . == $item.id) then ($item.folder | with_id($item.id)) else $item.folder end) as $folder
        | ($item.attachments | map(.fileName | base_name | ascii_downcase)) as $names
        | $item.attachments[] | . as $attachment
        | ($attachment.fileName | base_name) as $name
        | [ $item.id,
            ($attachment.id // $attachment.fileName),
            (if ([$names[] | select(. == ($name | ascii_downcase))] | length) > 1
             then $dir + $folder + "/" + ($name | with_id($attachment.id))
             else $dir + $folder + "/" end) ]
        | @tsv' <<<"$items_json")
    rm -f "$attachment_err"
    if [[ $attachments_failed -gt 0 ]]; then
        log_error "$attachments_failed attachment(s) could not be saved."
        log_hint "A reverse proxy that intercepts /attachments/ is a common cause: the CLI is handed a login page and cannot decrypt it. Check that path is reachable."
    fi
    log_info "Attachments: $attachments_saved saved, $attachments_failed failed."
    # What was saved is encrypted even when some downloads failed: a partial
    # backup is still worth keeping, and the run is reported as incomplete anyway.
    # If encryption fails there is no plain fallback; the run fails instead.
    if [[ $attachments_encryption -eq 1 ]] && [[ $attachments_saved -gt 0 ]]; then
        log_info "Encrypting the attachments..."
        attachments_archive="${runtime_save_folder_attachments%/}/attachments.tar.gz.gpg"
        if encrypt_folder "$attachments_staging" "$attachments_archive"; then
            log_info "Saved $attachments_archive"
        else
            archive_failed=1
            log_error "The attachments could not be encrypted, so none were kept."
        fi
    fi
    if [[ -n $attachments_staging ]]; then
        rm -rf "$attachments_staging"
        attachments_staging=""
    fi
elif [[ $items_listed -eq 1 ]]; then
    log_info "No attachments exist, so nothing to export."
fi

# 3. Report items in the Trash (cannot be exported)
trash_count=$(bw list items --trash | jq -r '. | length')

if [[ $trash_count -gt 0 ]]; then

    log_info "You have $trash_count items in the trash that cannot be exported."

fi

# 4. Export the organization vaults
# They go last because the CLI logs itself out when the server rejects one, and
# everything after that fails with "You are not logged in." When they ran
# before the attachments, an organization the account could never export took
# the attachments down with it.
#
# Only a confirmed Owner or Admin can export an organization: Vaultwarden
# answers anyone else with a 401. The CLI does not show a custom role's
# permissions, and Vaultwarden reports its managers as custom, so a detected
# organization is exported for those two roles only. One named in
# BW_ORGANIZATIONS_LIST is always tried.
# blocker: why this account cannot export the organization, empty if it can.
# A role or status the CLI does not report as a number is not ours to judge, so
# that organization is tried, as it always was.
org_export_blocker='def blocker:
    if (.status | type) != "number" or (.type | type) != "number" then ""
    elif .status == -1 then "your access to it is revoked"
    elif .status != 2 then "your membership is not confirmed"
    elif .type == 0 or .type == 1 then ""
    elif .type == 4 then "the CLI cannot tell whether your role (Custom) may export it"
    else "your role (\({"2": "User", "3": "Manager"}[.type | tostring] // "type \(.type)")) cannot export it"
    end;'
orgs_json='[]'
orgs_listed=0
organizations_skipped=0
organizations_exported=0
organizations_failed=0
if [[ $organizations_none -eq 1 ]]; then
    :
elif [[ $organization_list == "" ]]; then
    # Anything but a JSON array is a failed listing, not an empty one.
    if orgs_json=$(bw list organizations) && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$orgs_json"; then
        orgs_listed=1
    else
        listings_failed=$((listings_failed + 1))
        orgs_json='[]'
        log_error "Could not list the organizations, so none were exported."
    fi
    # Only the ID is logged: it is what BW_ORGANIZATIONS_LIST takes, and the
    # name is vault data, which the log never carries.
    while IFS=$'\t' read -r org_id org_verdict org_reason; do
        if [[ $org_verdict == export ]]; then
            organization_list+="${organization_list:+,}$org_id"
        else
            organizations_skipped=$((organizations_skipped + 1))
            log_info "Skipping organization $org_id: $org_reason."
            if [[ $org_verdict == custom ]]; then
                log_hint "If it may, add its ID to BW_ORGANIZATIONS_LIST."
            fi
        fi
    done < <(jq -r "$org_export_blocker"'
        .[] | blocker as $why
        | [ .id,
            (if $why == "" then "export" elif .type == 4 then "custom" else "skip" end),
            $why ]
        | join("\t")' <<<"$orgs_json")
else
    # Here the listing only explains a failed export, so failing is not an error.
    orgs_json=$(bw list organizations 2>/dev/null) || orgs_json='[]'
fi

if [[ -n "$organization_list" ]]; then
    IFS=', ' read -r -a array <<<"$organization_list"
    for org_id in "${array[@]}"; do
        failed_before=$exports_failed
        if [[ $password1 == "" ]]; then
            log_info "Exporting organization $org_id to an unencrypted file..."
            run_export "organization vault $org_id" --organizationid "$org_id" --format json --output "$runtime_save_folder"
        else
            log_info "Exporting organization $org_id to a password-encrypted file..."
            run_export "organization vault $org_id" --organizationid "$org_id" --format encrypted_json --output "$runtime_save_folder"
        fi
        if [[ $exports_failed -eq $failed_before ]]; then
            organizations_exported=$((organizations_exported + 1))
        else
            organizations_failed=$((organizations_failed + 1))
            org_reason=$(jq -r --arg id "$org_id" "$org_export_blocker"'
                first(.[] | select(.id == $id) | blocker) // ""' <<<"$orgs_json" 2>/dev/null) || org_reason=""
            if [[ -n "$org_reason" ]]; then
                log_hint "$org_reason. Only a confirmed Owner or Admin, or a custom role allowed to, can export an organization."
                log_hint "Remove it from BW_ORGANIZATIONS_LIST."
            fi
        fi
    done
elif [[ $organizations_skipped -gt 0 ]]; then
    log_info "None of your organizations can be exported with your role, so none were exported."
elif [[ $orgs_listed -eq 1 ]]; then
    log_info "No organizational vault exists, so nothing to export."
fi

if [[ $((exports_failed + listings_failed)) -gt 0 ]]; then
    log_error "$exports_failed vault export(s) and $listings_failed vault listing(s) failed."
else
    log_info "Vault export complete."
fi

# One pass over what this run wrote, for the filesystems where the umask is not
# the whole story (default ACLs). Only this run's two folders, never the paths
# they sit in, which belong to whoever mounted them. A filesystem that has no
# modes, such as an NTFS share, says so and is left alone: the run still worked.
if [[ $backup_private -eq 1 ]]; then
    if ! chmod -R u+rwX,go-rwx "$runtime_save_folder" "$runtime_save_folder_attachments" 2>/dev/null; then
        log_warn "Could not restrict the permissions of this backup. Its filesystem may not support them."
    fi
fi

close_session

# Rotation deletes old backups to make room for this one. When this one is
# missing a vault or attachments that trades a complete backup for an incomplete
# one, and repeated often enough it leaves nothing complete at all. A failed
# export may still have left its (empty) folder behind, which rotation would
# count as a backup.
#
# KEEP_LAST_BACKUPS keeps the N newest backups. KEEP_GFS ("7d:4w:6m") keeps the
# newest backup of each recent day, week, month and year, so a deletion noticed
# weeks later can still be undone. Set both and a backup either one keeps is
# kept. See retention.sh.
backups_deleted=0
retention_failed=0
failures=$((exports_failed + listings_failed + attachments_failed + archive_failed))

# $1: the folder holding the backups. $2: what they are, for the log.
rotate_folder() {
    local folder="$1" what="$2" doomed name
    doomed=$(find "$folder" -mindepth 1 -maxdepth 1 -type d -name '*-bw-export' -printf '%f\n' |
        backups_to_delete "${KEEP_LAST_BACKUPS}" "${KEEP_GFS}") || return 1
    [[ -n $doomed ]] || return 0
    while IFS= read -r name; do
        log_info "Deleting old $what backup: ${folder%/}/$name"
        rm -rf "${folder:?}/${name:?}"
        backups_deleted=$((backups_deleted + 1))
    done <<<"$doomed"
}

if [[ -n "${KEEP_LAST_BACKUPS}${KEEP_GFS}" ]] && [[ $failures -gt 0 ]]; then
    log_warn "This backup is incomplete, so no old backup is deleted for it."
    log_hint "Fix the failure; rotation resumes with the next complete backup."
elif [[ -n "${KEEP_LAST_BACKUPS}${KEEP_GFS}" ]]; then
    log_info "Rotating old backups..."
    if [[ -n ${KEEP_LAST_BACKUPS} ]] && ! [[ ${KEEP_LAST_BACKUPS} =~ ^[0-9]+$ ]]; then
        log_error "KEEP_LAST_BACKUPS=${KEEP_LAST_BACKUPS} is not a number." >&2
        retention_failed=1
    fi
    if [[ -n ${KEEP_GFS} ]] && ! gfs_parse "${KEEP_GFS}" >/dev/null; then
        log_error "KEEP_GFS=${KEEP_GFS} is not valid." >&2
        log_hint "Use counts of days, weeks, months and years, e.g. 7d:4w:6m." >&2
        retention_failed=1
    fi
    if [[ $retention_failed -eq 0 ]]; then
        [[ -n ${KEEP_LAST_BACKUPS} ]] && log_info "Keeping the last ${KEEP_LAST_BACKUPS} backup(s)."
        if [[ -n ${KEEP_GFS} ]]; then
            read -r gfs_d gfs_w gfs_m gfs_y <<<"$(gfs_parse "${KEEP_GFS}")"
            log_info "Keeping the newest backup of each of the last $gfs_d day(s), $gfs_w week(s), $gfs_m month(s) and $gfs_y year(s)."
        fi
        rotate_folder "$save_folder" "vault" || retention_failed=1
        rotate_folder "$save_folder_attachments" "attachment" || retention_failed=1
        if [[ $retention_failed -ne 0 ]]; then
            log_error "Could not work out which old backups to delete, so none were."
        fi
    fi
    log_info "Old backups deleted: $backups_deleted."
fi

# What this run did, for the log and for the notification, which reads the
# block between the two marker lines. Printed before the final errors so a
# failure's notification still ends with them.
format_duration() {
    local s=$1
    if ((s >= 3600)); then
        printf '%dh %dm %ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
    elif ((s >= 60)); then
        printf '%dm %ds' $((s / 60)) $((s % 60))
    else
        printf '%ds' "$s"
    fi
}
backup_bytes=$(du -sb "$runtime_save_folder" "$runtime_save_folder_attachments" 2>/dev/null | awk '{ n += $1 } END { print n + 0 }')
backup_size=$(numfmt --to=iec-i --suffix=B "$backup_bytes" 2>/dev/null) || backup_size="$backup_bytes bytes"
if [[ $password1 == "" ]]; then vault_mode="unencrypted"; else vault_mode="encrypted"; fi
if [[ $personal_exported -eq 1 ]]; then personal_line="exported ($vault_mode)"; else personal_line="FAILED"; fi
if [[ $organizations_none -eq 1 ]]; then
    organizations_line="none (BW_ORGANIZATIONS_LIST=none)"
else
    organizations_line="$organizations_exported exported, $organizations_skipped skipped, $organizations_failed failed"
fi
attachments_line="$attachments_saved saved, $attachments_failed failed"
if [[ $archive_failed -ne 0 ]]; then
    attachments_line+=" (encryption FAILED, none kept)"
elif [[ $attachments_saved -gt 0 ]]; then
    if [[ $attachments_encryption -eq 1 ]]; then attachments_line+=" (encrypted archive)"; else attachments_line+=" (unencrypted)"; fi
fi
echo
echo "----- Summary -----"
echo "Duration: $(format_duration $((SECONDS - run_started)))"
echo "Personal vault: $personal_line"
echo "Organizations: $organizations_line"
echo "Attachments: $attachments_line"
[[ ${trash_count:-0} -gt 0 ]] && echo "Trash (not exported): $trash_count item(s)"
echo "Backup size: $backup_size"
[[ -n "${KEEP_LAST_BACKUPS}${KEEP_GFS}" ]] && echo "Old backups deleted: $backups_deleted"
echo "-------------------"

# A missing vault export or attachment is an incomplete backup, so say so and
# fail. Silence here is what let a broken backup look healthy run after run.
if [[ $exports_failed -gt 0 ]]; then
    log_error "Exporting finished, but $exports_failed vault export(s) failed."
fi
if [[ $listings_failed -gt 0 ]]; then
    log_error "Exporting finished, but $listings_failed vault listing(s) failed."
fi
if [[ $attachments_failed -gt 0 ]]; then
    log_error "Exporting finished, but $attachments_failed attachment(s) are missing."
fi
if [[ $archive_failed -gt 0 ]]; then
    log_error "Exporting finished, but the attachments could not be encrypted."
fi
if [[ $failures -gt 0 ]]; then
    log_error "This backup is incomplete."
    exit 1
fi
if [[ $retention_failed -ne 0 ]]; then
    log_error "The backup is complete, but old backups were not rotated."
    exit 1
fi

log_info "Export finished successfully."
