#!/usr/bin/env bash
/etc/cont-init.d/10-adduser

Yellow='\033[0;33m'       # Yellow
Cyan='\033[0;36m'         # Cyan

send_notification () {
    set -xe
    echo -e "\n${Cyan}Notification enabled: $NOTIFICATION_URL "
    /app/shoutrrr send -m "$(tail -n 15 "$logfile")"  -u "$NOTIFICATION_URL"
}

if [[ -n "${NOTIFICATION_URL}" ]]; then
    /app/shoutrrr send -m "Bitwarden/Vaultwarden Export: Started"  -u "$NOTIFICATION_URL"
fi

#Base Command
command="su bitwarden -c /app/bw_export.sh "
logfile=/app/bw-export-logfile.log

if [[ -n "${INFISICAL_TOKEN}" ]]; then
    if [[ -n "${INFISICAL_PATH}" ]]; then
        infisicalpath="--path=${INFISICAL_PATH}"
    fi
    echo -e "\n${Yellow}Infisical enabled! "
    #Run this command to test connection with Infiscal
    infisical run "$infisicalpath" --command="echo BW_CLIENTID:$BW_CLIENTID"
    returncode=$?
    if [[ -n "${NOTIFICATION_URL}" ]]  &&  [[ "$returncode" -ne "0" ]]; then
        send_notification
        exit 1
    fi
    command="infisical run $infisicalpath --command='$command'"
fi

if [[ -n "${FILE_LOG}" ]]; then
    echo -e "\n${Cyan}Output log enabled: $FILE_LOG "
    logfile=$FILE_LOG
fi

command="$command 2>&1 | tee $logfile"
set -o pipefail
eval "$command"
return=$?
echo Return Code: $return

if [[ -n "${NOTIFICATION_URL}" ]]; then
    if [[ "$return" -ne "0" ]]; then
        send_notification
    else
        /app/shoutrrr send -m "Bitwarden/Vaultwarden Export: Finish correctly ✅"  -u "$NOTIFICATION_URL"
    fi
fi

