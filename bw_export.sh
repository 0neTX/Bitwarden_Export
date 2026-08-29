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
Yellow='\033[0;33m'  # Yellow
IYellow='\033[0;93m' # Yellow
IGreen='\033[0;92m'  # Green
Cyan='\033[0;36m'    # Cyan
UCyan='\033[4;36m'   # Cyan
UWhite='\033[4;37m'  # White
Blue='\033[0;34m'    # Blue

echo Starting ...
#Set locations to save export files
if [[ -z "${OUTPUT_PATH}" ]]; then
    echo -e "\n$(date '+%F %T') ${Cyan}Info: OUTPUT_PATH enviroment not provided. Using default value: /var/data"
    save_folder="/var/data/"
else
    save_folder="${OUTPUT_PATH}"
    if [[ ! -d "$save_folder" ]]; then
        echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Could not find the folder in which to save the files: $save_folder "
        echo
        params_validated=-1
    fi
fi

#Set locations to save attachment files
if [[ -z "${ATTACHMENTS_PATH}" ]]; then
    save_folder_attachments="/var/attachments/"
    echo -e "\n$(date '+%F %T') ${Cyan}Info: ATTACHMENTS_PATH enviroment not provided. Using default value: /var/attachments"
else
    save_folder_attachments="${ATTACHMENTS_PATH}"
    if [[ ! -d "$save_folder_attachments" ]]; then
        echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Could not find the folder in which to save the attachments files: $save_folder_attachments "
        echo
        params_validated=-1
    fi
fi

#Set Vaultwarden own server.
# To obtain your organization_id value, open a terminal and type:
#   bw login #(follow the prompts);
if [[ -z "${BW_URL_SERVER}" ]]; then
    echo -e -n "$Cyan" # set text = yellow
    echo -e "\nInfo: BW_URL_SERVER enviroment not provided."

    echo -n "$(date '+%F %T') If you have your own Bitwarden or Vaulwarden server, set in the environment variable BW_URL_SERVER its url address. "
    echo -n "$(date '+%F %T') Example: https://skynet-vw.server.com"
    echo
else
    bw_url_server="${BW_URL_SERVER}"
fi

#Set Bitwarden session authentication.
# To obtain your organization_id value, open a terminal and type:
#   bw login #(follow the prompts);
if [[ -z "${BW_CLIENTID}" ]]; then

    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: BW_CLIENTID enviroment variable not provided, exiting..."

    echo -n "$(date '+%F %T') Your Bitwarden Personal API Key can be obtain in:"
    echo -n "$(date '+%F %T') https://bitwarden.com/help/personal-api-key/"
    params_validated=-1
else
    if test -f "${BW_CLIENTID}"; then
        client_id=$(<"${BW_CLIENTID}")
    else
        client_id="${BW_CLIENTID}"
    fi

fi

if [[ -z "${BW_CLIENTSECRET}" ]]; then

    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: BW_CLIENTSECRET enviroment variable not provided, exiting..."

    echo -n "$(date '+%F %T') Your Bitwarden Personal API Key can be obtain in:"
    echo -n "$(date '+%F %T') https://bitwarden.com/help/personal-api-key/"
    params_validated=-1
else
    if test -f "${BW_CLIENTSECRET}"; then
        client_secret=$(<"${BW_CLIENTSECRET}")
    else
        client_secret="${BW_CLIENTSECRET}"
    fi

fi

if [[ -z "${BW_PASSWORD}" ]]; then

    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: BW_PASSWORD enviroment variable not provided, exiting..."

    params_validated=-1
else

    if test -f "${BW_PASSWORD}"; then
        bw_password=$(<"${BW_PASSWORD}")
    else
        bw_password="${BW_PASSWORD}"
    fi
fi

#Set Organization ID (if applicable)
if [[ -z "${BW_ORGANIZATIONS_LIST}" ]]; then
    echo -e "\n$(date '+%F %T') ${Cyan} BW_ORGANIZATIONS_LIST enviroment not provided. All detected organizations will be exported. "
else
    organization_list="${BW_ORGANIZATIONS_LIST}"
fi

#Check export password
if [[ -z "${EXPORT_PASSWORD}" ]]; then

    echo
    echo -e "\n$(date '+%F %T') ${IYellow}-------------------------------------------------------------------------------------------------------------"
    echo -e "\n$(date '+%F %T') ${IYellow}Warning: EXPORT_PASSWORD enviroment not provided. Exports require a password to securize your exported vault."
    echo -e "\n$(date '+%F %T') ${IYellow}-------------------------------------------------------------------------------------------------------------"
    echo
    password1=""

else
    echo -e "\n$(date '+%F %T') ${Cyan}Info:  Be sure to save your EXPORT_PASSWORD in a safe place!"
    if test -f "${EXPORT_PASSWORD}"; then
        password1=$(<"${EXPORT_PASSWORD}")
    else
        password1="${EXPORT_PASSWORD}"
    fi
fi

# Check if required parameters has beed proviced.
if [[ $params_validated != 0 ]]; then
    echo -e "\n$(date '+%F %T') ${IYellow}One or more required environment variables have not been set."
    echo -e "${IYellow}Please check the required environment variables:"
    echo -e "${IYellow}BW_CLIENTID,BW_CLIENTSECRET,BW_PASSWORD"
    exit 1
fi

session_closed=0

# Close the Bitwarden CLI session and wipe the credentials from the environment.
# Idempotent: safe to call explicitly and from the EXIT trap.
close_session() {
    if [[ $session_closed -ne 0 ]]; then
        return 0
    fi
    session_closed=1
    echo "$(date '+%F %T') Closing Bitwarden CLI session..."
    bw lock >/dev/null 2>&1 || true
    bw logout >/dev/null 2>&1 || true
    BW_CLIENTID=
    BW_CLIENTSECRET=
    BW_SESSION=
}

echo "$(date '+%F %T') $(date '+%F %T') Starting exporting..."
echo

BW_CLIENTID=$client_id
BW_CLIENTSECRET=$client_secret

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
    echo "$(date '+%F %T') Existing session detected. Logging out before starting..."
    bw logout >/dev/null 2>&1 || true
    if [[ $(bw status | jq -r .status) != "unauthenticated" ]]; then
        echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Could not log out the previous session."
        echo "$(date '+%F %T') Remove the Bitwarden CLI data directory or recreate the container, then retry."
        echo
        exit 1
    fi
fi

if [[ $bw_url_server != "" && $bw_url_server != *"bitwarden.com" ]]; then
    echo "$(date '+%F %T') Setting custom server..."
    if ! bw config server "$bw_url_server" --nointeraction; then
        echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Failed to set the server url: $bw_url_server"
        echo
        exit 1
    fi
    echo
fi

echo "$(date '+%F %T') Performing login..."
bw login --apikey --method 0 --quiet --nointeraction
if [[ $(bw status | jq -r .status) == "unauthenticated" ]]; then
    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Failed to login."
    echo
    exit 1
fi

#Unlock the vault
echo "$(date '+%F %T') Unlocking the vault..."
session_key=$(bw unlock "$bw_password" --raw)
unlock_result=$?
#Verify that unlock succeeded
if [[ $unlock_result -ne 0 ]] || [[ -z $session_key ]]; then
    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Failed to unlock vault with BW_PASSWORD."
    exit 1
else
    echo "$(date '+%F %T') Vault unlocked."
fi
#Export the session key as an env variable (needed by BW CLI)
export BW_SESSION="$session_key"

#Check if the user has decided to enter a password or save unencrypted
if [[ $password1 == "" ]]; then
    echo -e "\n$(date '+%F %T') ${IYellow}WARNING! Your vault contents will be saved to an unencrypted file."
    echo "$(date '+%F %T') WARNING! Your vault contents will be saved to an unencrypted file."
else
    echo -e "\n$(date '+%F %T') ${Cyan}Info: Password for encrypted export has been provided."
fi

echo "$(date '+%F %T') Performing vault exports..."

# 1. Export the personal vault
if [[ ! -d "$save_folder" ]]; then
    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Could not find the folder in which to save the files. Path: $save_folder"
    echo
    exit 1
fi

working_folder=$(date '+%Y%m%d%H%M%S')-bw-export

runtime_save_folder=$save_folder/$working_folder/
runtime_save_folder_attachments=$save_folder_attachments/$working_folder/

if [[ ! -d "$runtime_save_folder" ]]; then
    mkdir "$runtime_save_folder"
fi

if [[ ! -d "$runtime_save_folder_attachments" ]]; then
    mkdir "$runtime_save_folder_attachments"
fi

if [[ $password1 == "" ]]; then
    echo
    echo "$(date '+%F %T') Exporting personal vault to an unencrypted file..."
    bw export --format json --output "$runtime_save_folder"
else
    echo
    echo "$(date '+%F %T') Exporting personal vault to a password-encrypted file..."
    bw export --format encrypted_json --password "$password1" --output "$runtime_save_folder"
fi

if [[ $organization_list == "" ]]; then
    list=$(bw list organizations | jq -r '.[] | .id' | tr '\n' ', ')
    if [[ -n "$list" ]]; then
        organization_list=${list::-1}
        if [[ -n "$organization_list" ]]; then
            echo -e "\n$(date '+%F %T') ${Cyan}Info: No  BW_ORGANIZATIONS_LIST provided. Exporting all organizations detected in vault"
        fi
    fi
fi

# 2. Export the organization vault (if specified)
if [[ -n "$organization_list" ]]; then
    IFS=', ' read -r -a array <<<"$organization_list"
    for org_id in "${array[@]}"; do
        if [[ $password1 == "" ]]; then
            echo
            echo "$(date '+%F %T') Exporting organization vault to an unencrypted file..."
            bw export --organizationid "$org_id" --format json --output "$runtime_save_folder"
        else
            echo
            echo "$(date '+%F %T') Exporting organization vault to a password-encrypted file..."
            bw export --organizationid "$org_id" --format encrypted_json --password "$password1" --output "$runtime_save_folder"
        fi
    done
else
    echo
    echo "$(date '+%F %T') No organizational vault exists, so nothing to export."
fi

# 3. Download all attachments (file backup)
# Item and file names are attacker-controlled: anyone who can put an item in a
# shared organization collection chooses them. They are therefore passed to the
# CLI as arguments and never interpolated into shell text.
#
# The item name also becomes a directory name, so it is reduced to something
# every target filesystem accepts: "/" and "\" would be read as path
# separators, and NTFS (this image is commonly bind-mounted onto Windows
# volumes) rejects < > : " | ? * and trailing dots or spaces outright.
attachments_failed=0
items_json=$(bw list items)
# An item without attachments carries an empty array, not null, so counting the
# attachments themselves is the only way to tell whether there is work to do.
if [[ $(jq '[.[] | (.attachments // [])[]] | length' <<<"$items_json") -gt 0 ]]; then
    echo
    echo "$(date '+%F %T') Saving attachments..."
    # The loop runs in this shell (process substitution, not a pipe), so the
    # count survives it. A failed download is only reported by the CLI's exit
    # status; on stdout it looks much like a successful one.
    while IFS=$'\t' read -r item_id file_name output_dir; do
        if ! bw get attachment "$file_name" --itemid "$item_id" --output "$output_dir"; then
            attachments_failed=$((attachments_failed + 1))
        fi
    done < <(jq -r --arg dir "$runtime_save_folder_attachments" '
        .[] | . as $item | (.attachments // [])[] | . as $attachment
        | (($item.name // "")
           | gsub("[/<>:\"\\\\|?*[:cntrl:]]"; "_")
           | sub(" +$"; "") | sub("\\.+$"; "")) as $folder
        | [ $item.id,
            $attachment.fileName,
            $dir + (if $folder == "" then "unnamed" else $folder end) + "/" ]
        | @tsv' <<<"$items_json")
    if [[ $attachments_failed -gt 0 ]]; then
        echo -e "\n$(date '+%F %T') ${IYellow}ERROR: $attachments_failed attachment(s) could not be saved."
        echo "$(date '+%F %T') A reverse proxy that intercepts /attachments/ is a common cause: the"
        echo "$(date '+%F %T') CLI is handed a login page and cannot decrypt it. Check that path is reachable."
    fi
else
    echo
    echo "$(date '+%F %T') No attachments exist, so nothing to export."
fi

echo
echo "$(date '+%F %T') Vault export complete."

# 4. Report items in the Trash (cannot be exported)
trash_count=$(bw list items --trash | jq -r '. | length')

if [[ $trash_count -gt 0 ]]; then

    echo -e "\n$(date '+%F %T') ${Cyan}Info: You have $trash_count items in the trash that cannot be exported."

fi

echo
close_session

if [ -n "${KEEP_LAST_BACKUPS}" ]; then
    echo "$(date '+%F %T') $(date '+%F %T') Starting cleaning previous backups..."
    echo
    re='^[0-9]+$'
    if ! [[ ${KEEP_LAST_BACKUPS} =~ $re ]]; then
        echo -e "\n$(date '+%F %T') ${IYellow}ERROR: KEEP_LAST_BACKUPS:${KEEP_LAST_BACKUPS} is not a number" >&2
        exit 1
    fi
    keep_backups="${KEEP_LAST_BACKUPS}"
    # Deleting vault exportings directories
    actual_num_backups=$(find "$save_folder" -path "*-bw-export" -type d | sort | wc -l)
    echo -e "\n$(date '+%F %T') ${Cyan}Info: Nº backups: $actual_num_backups"
    echo -e "$(date '+%F %T') ${Cyan}Info: Max Nº backups: $keep_backups"
    if [[ $actual_num_backups -gt $keep_backups ]]; then
        for F in $(find "$save_folder" -path "*-bw-export" -type d | sort | head -"$(("$actual_num_backups" - "$keep_backups"))"); do
            echo -e "$(date '+%F %T') ${Blue} Deleting exported vault:$F"
            rm -rf "$F"
        done
    fi
    # Deleteting attachment exporting directories
    actual_num_backups=$(find "$save_folder_attachments" -path "*-bw-export" -type d | sort | wc -l)
    if [[ $actual_num_backups -gt $keep_backups ]]; then
        echo -e "\n$(date '+%F %T') ${Cyan}Info: Nº backups: $actual_num_backups"
        echo -e "$(date '+%F %T') ${Cyan}Info: Max Nº backups: $keep_backups"
        for F in $(find "$save_folder_attachments" -path "*-bw-export" -type d | sort | head -$(("$actual_num_backups" - "$keep_backups"))); do
            echo -e "$(date '+%F %T') ${Blue} Deleting exported attachment:$F"
            rm -rf "$F"
        done
    fi
    echo "$(date '+%F %T') $(date '+%F %T') Finish clean previous backups..."
fi

# An export missing attachments is an incomplete backup, so say so and fail.
# Silence here is what let a broken backup look healthy run after run.
if [[ $attachments_failed -gt 0 ]]; then
    echo -e "\n$(date '+%F %T') ${IYellow}ERROR: Exporting finished, but $attachments_failed attachment(s) are missing."
    echo "$(date '+%F %T') This backup is incomplete."
    echo
    exit 1
fi

echo -e "\n$(date '+%F %T') ${IGreen} Info: Exporting finished. Have a good day"
echo
