# Notifications through shoutrrr (NOTIFICATION_URL). Sourced by entrypoint.sh,
# and kept in a file of its own for the same reason as ping.sh: entrypoint.sh
# cannot be sourced by a test. See tests/run_notify_tests.sh.
# shellcheck shell=bash

if ! declare -F resolve_secret >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/secrets.sh"
fi

# Which outcomes are sent. NOTIFICATION_LEVEL is "all" (the default: start,
# success and failure) or "failure" (only a failed run). Anything else counts as
# "all": a typo must never be the reason an alert is not sent.
notify_level() {
    case "$(printf '%s' "${NOTIFICATION_LEVEL:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" in
        failure) echo failure ;;
        *) echo all ;;
    esac
}

# Prints a warning when NOTIFICATION_LEVEL is set to something that is neither
# of its two values. Prints nothing otherwise.
notify_level_warning() {
    local value
    value="$(printf '%s' "${NOTIFICATION_LEVEL:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        "" | all | failure) ;;
        *) echo -e "${Yellow:-}Warning: NOTIFICATION_LEVEL must be all or failure, not \"${NOTIFICATION_LEVEL}\". Sending every notification." ;;
    esac
}

# True when a message of kind $1 (start, success or failure) is to be sent. A
# failure always is.
notify_wanted() {
    [[ "$1" == failure ]] || [[ "$(notify_level)" == all ]]
}

# Sends $1 to NOTIFICATION_URL, or does nothing when that is not set.
#
# The URL carries the service's credentials (a Telegram bot token, a Gotify app
# token), so it is kept out of three places:
#   - the log: it is never printed, and tracing is switched off first, since a
#     caller running under "set -x" would otherwise print this whole function;
#   - the process list: shoutrrr reads it from SHOUTRRR_URL rather than from -u,
#     because any user on the host can read a process's arguments with ps, but
#     only its owner and root can read its environment;
#   - shoutrrr's own error output: a failed request is reported with the address
#     it was sent to, which for Telegram has the token in its path.
#
# An empty message is replaced, because some services reject one (Telegram
# answers "message text is empty") and the alert would be lost.
#
# Always returns 0: a notification outage must not turn a good backup into a bad
# exit code, or change the code of a bad one.
send_message() {
    set +x
    local url message="$1"
    url="$(resolve_secret NOTIFICATION_URL)"
    [[ -z "$url" ]] && return 0
    [[ -z "$message" ]] && message="Bitwarden/Vaultwarden Export: (no log output to send)"
    if ! SHOUTRRR_URL="$url" "${SHOUTRRR_BIN:-/app/shoutrrr}" send -m "$message" 2>/dev/null; then
        echo -e "${Yellow:-}Warning: sending the notification failed; continuing."
    fi
    return 0
}
