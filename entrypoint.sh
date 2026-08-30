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

# "docker stop" signals PID 1, which is this script. Two things stop that from
# reaching the export: a command run in the foreground blocks the trap until it
# returns, and "su" answers SIGTERM by killing its child outright rather than
# passing it on. So run the pipeline in the background and signal the export
# directly, giving it the chance to log out of the Bitwarden CLI on its way out.
# shellcheck disable=SC2329  # invoked from the traps below
forward_signal() {
    # Only "no process matched" is expected on stderr here, never a missing pkill:
    # that is checked once below, so this stays quiet.
    pkill -"$1" -f '/app/bw_export.sh' 2>/dev/null
}
if command -v pkill >/dev/null 2>&1; then
    trap 'forward_signal TERM' TERM
    trap 'forward_signal INT' INT
else
    # Say so rather than degrade quietly: without this the export is killed
    # outright and leaves a logged-in CLI session for the next run to clean up.
    echo -e "\n${Yellow}Warning: pkill (procps) not found. A container stop will not reach the export,"
    echo -e "${Yellow}so it cannot close its Bitwarden CLI session. Install procps in the image."
fi

# The subshell keeps the pipeline's status (with pipefail) addressable as one
# job; waiting on the pipeline itself would report what "tee" did, not the export.
( eval "$command" ) &
child=$!
wait "$child"
return=$?
# A trapped signal makes wait return early, before the export has finished
# cleaning up. Keep waiting for the real status.
while kill -0 "$child" 2>/dev/null; do
    wait "$child"
    return=$?
done
trap - TERM INT
echo Return Code: $return

if [[ -n "${NOTIFICATION_URL}" ]]; then
    if [[ "$return" -ne "0" ]]; then
        send_notification || true
    else
        /app/shoutrrr send -m "Bitwarden/Vaultwarden Export: Successfully completed ✅"  -u "$NOTIFICATION_URL" || true
    fi
fi

# Report what the export actually did. Without this the container always exited
# 0, so "restart: on-failure", cron and every orchestrator saw a broken backup
# as a successful one.
exit "$return"

