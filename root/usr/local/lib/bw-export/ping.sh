# Monitoring pings for an external watchdog: healthchecks, uptime-kuma, or any
# dead man's switch. Sourced by entrypoint.sh.
#
# This lives in its own file so the URL building can be unit tested.
# entrypoint.sh cannot be sourced for that: it runs the container entrypoint on
# the way past, and needs su, pkill, shoutrrr and 10-adduser to exist. Here the
# interesting half is a pure function. See tests/run_ping_tests.sh.
# shellcheck shell=bash

# Builds the URL to ping for one event, or prints nothing when no ping is due.
#
#   $1  base URL, normally $PING_URL
#   $2  event: start, success or failure
#   $3  the export's exit code, used by {code} on a failure
#
# Two placeholders, each with its own vocabulary, because the services disagree.
# healthchecks takes the outcome as a path segment (/start, /0, /3), while
# uptime-kuma takes it as a query parameter and counts anything that is not
# literally "up" as a failure, so one vocabulary cannot serve both:
#
#   {code}    start | 0 | <exit code>
#   {status}  (no start ping) | up | down
#
# A URL using {status} gets no start ping: that vocabulary has no value meaning
# "starting", and a push monitor has no concept of one. With no placeholder at
# all the value is appended as a path segment, so pasting a healthchecks ping URL
# unchanged does the right thing.
#
# Substitution is parameter expansion, never eval. The only values that can
# reach a URL are start, up, down and an integer, so nothing needs escaping.
build_ping_url() {
    local base="$1" event="$2" code="${3:-0}"
    local code_value status_value has_code=1 has_status=1

    [[ -z "$base" ]] && return 0

    case "$event" in
        start)   code_value="start"; status_value="" ;;
        success) code_value="0";     status_value="up" ;;
        failure) code_value="$code"; status_value="down" ;;
        *)       return 0 ;;
    esac

    # Decided from the URL as given, before any substitution removes a token.
    [[ "$base" == *"{code}"* ]]   || has_code=0
    [[ "$base" == *"{status}"* ]] || has_status=0

    if [[ "$has_status" -eq 1 ]]; then
        [[ -z "$status_value" ]] && return 0
        base="${base//\{status\}/$status_value}"
    fi

    if [[ "$has_code" -eq 1 ]]; then
        base="${base//\{code\}/$code_value}"
    elif [[ "$has_status" -eq 0 ]]; then
        base="${base%/}/$code_value"
    fi

    printf '%s\n' "$base"
}

# Pings the monitor for one event. Never fails the run.
#
#   $1  event: start, success or failure
#   $2  the export's exit code
# shellcheck disable=SC2329  # called from entrypoint.sh, not from this file
send_ping() {
    local url
    url="$(build_ping_url "${PING_URL:-}" "$1" "${2:-0}")"
    [[ -z "$url" ]] && return 0

    # The URL carries the monitor's token, and send_notification leaves "set -x"
    # on in this shell, which would trace it into the container log. The event is
    # worth logging; the URL is not.
    set +x
    echo -e "\n${Cyan:-}Monitoring ping: $1 "

    # No -S, and the warning below names no URL: curl reports some failures with
    # the address attached, which would put the token in the log. --max-time
    # matters as much as --retry: the result ping runs after a backup that may
    # have succeeded, and an unreachable monitor must not hold the container
    # open. The failure is swallowed on purpose, so a monitoring outage cannot
    # turn a good backup into a bad exit code.
    if ! curl -fs -o /dev/null --max-time 10 --retry 3 "$url"; then
        echo -e "${Yellow:-}Warning: monitoring ping ($1) failed; continuing."
    fi
    return 0
}
