#!/usr/bin/env bash
ADDUSER_BIN="${ADDUSER_BIN:-/etc/cont-init.d/10-adduser}"
LOG_LIB="${LOG_LIB:-/usr/local/lib/bw-export/log.sh}"
PING_LIB="${PING_LIB:-/usr/local/lib/bw-export/ping.sh}"
NOTIFY_LIB="${NOTIFY_LIB:-/usr/local/lib/bw-export/notify.sh}"
BW_EXPORT_SCRIPT="${BW_EXPORT_SCRIPT:-/app/bw_export.sh}"
SUPERCRONIC_BIN="${SUPERCRONIC_BIN:-supercronic}"
CRONTAB_FILE="${CRONTAB_FILE:-/tmp/bw-export.crontab}"
LOCK_FILE="${LOCK_FILE:-/tmp/bw-export.lock}"
RUN_AS_USER="${RUN_AS_USER-bitwarden}"
FILE_LOG_MAX_BYTES="${FILE_LOG_MAX_BYTES:-104857600}"
# Who this container was started as (overridable so the tests can pretend), and
# the image's own folder, which only the image's user can write to.
ENTRYPOINT_UID="${ENTRYPOINT_UID:-$(id -u)}"
APP_DIR="${APP_DIR:-/app}"


# Started as a user other than root (compose "user: 1000:1000"): there is no
# user to switch to, and no permission to create one, so the export runs as
# that user directly. This is what lets the container run with
# "cap_drop: [ALL]" and "no-new-privileges".
if [[ "$ENTRYPOINT_UID" -ne 0 ]]; then
    RUN_AS_USER=""
fi

# Where the image keeps its own state is not writable with "read_only: true",
# or for a user that is not the image's. The CLI's session data and the default
# log then go to the temporary folder (a tmpfs in the hardened setup), which
# also keeps the CLI's tokens off disk. Set by this, the first invocation, and
# inherited by every scheduled run.
if [[ ! -w "$APP_DIR" ]]; then
    export LOGFILE_DEFAULT="${LOGFILE_DEFAULT:-${TMPDIR:-/tmp}/bw-export-logfile.log}"
    if [[ -z "${BITWARDENCLI_APPDATA_DIR:-}" ]]; then
        export BITWARDENCLI_APPDATA_DIR="${TMPDIR:-/tmp}/bitwarden-cli"
        # Private: it holds the CLI's tokens while a run is logged in.
        [[ -d "$BITWARDENCLI_APPDATA_DIR" ]] || mkdir -m 700 "$BITWARDENCLI_APPDATA_DIR" 2>/dev/null || true
    fi
fi
# A uid with no entry in /etc/passwd gets HOME=/, which it cannot write to.
if [[ ! -w "${HOME:-/}" ]]; then
    export HOME="${TMPDIR:-/tmp}"
fi

# Monitoring pings (PING_URL), for healthchecks, uptime-kuma or any dead man's
# switch. Deliberately independent of NOTIFICATION_URL: one tells a person, the
# other tells a machine, and neither is consulted to decide the other.
# shellcheck disable=SC1090
. "$LOG_LIB"
# shellcheck disable=SC1090
. "$PING_LIB"
# shellcheck disable=SC1090
. "$NOTIFY_LIB"

# The first lines of every run: what a support request needs before anything
# else. Versions, mode and who the export runs as, and which optional features
# are on, by name only: no URL, token or path that could identify a server.
run_header() {
    local run_uid run_gid
    if [[ -n "$RUN_AS_USER" ]] && id "$RUN_AS_USER" >/dev/null 2>&1; then
        run_uid=$(id -u "$RUN_AS_USER"); run_gid=$(id -g "$RUN_AS_USER")
    else
        run_uid=$(id -u); run_gid=$(id -g)
    fi
    log_info "bw-export ${BW_EXPORT_VERSION:-unknown}, Bitwarden CLI ${BW_CLI_VERSION:-unknown}"
    if [[ -n "${CRON:-}" ]]; then
        log_info "Mode: scheduled (CRON=$CRON), timezone ${TZ:-UTC}"
    else
        log_info "Mode: one backup, then exit, timezone ${TZ:-UTC}"
    fi
    log_info "Runs as uid $run_uid, gid $run_gid"
    local notifications="off" ping="off" infisical="off" vaults="one"
    if [[ -n "$(resolve_secret NOTIFICATION_URL 2>/dev/null)" ]]; then
        if [[ "$(notify_level)" == failure ]]; then notifications="failures only"; else notifications="on"; fi
    fi
    [[ -n "$(resolve_secret PING_URL 2>/dev/null)" ]] && ping="on"
    [[ -n "${INFISICAL_TOKEN:-}" ]] && infisical="on"
    [[ -n "${BW_VAULTS:-}" ]] && vaults="several (BW_VAULTS)"
    log_info "Vaults: $vaults; notifications: $notifications; monitoring ping: $ping; Infisical: $infisical; log file: $([[ -n "${FILE_LOG:-}" ]] && echo on || echo off)"
}

run_once() {
    local run_log
    run_log=$(mktemp)

    # Reporting the outcome from a trap is what covers every exit path, including
    # the Infisical check below, which exits on its own. Running last also makes the
    # order against the notifications below stop mattering.
    # Invoked from the EXIT trap, which shellcheck cannot see: older versions call
    # this unreachable (SC2317), newer ones call it uninvoked (SC2329).
    # shellcheck disable=SC2329,SC2317
    ping_on_exit() {
        local status=$?
        rm -f "$run_log"
        if [[ "$status" -eq 0 ]]; then
            send_ping success "$status"
        else
            send_ping failure "$status"
        fi
    }
    trap ping_on_exit EXIT

    # The run summary bw_export.sh prints between two marker lines (duration,
    # what was exported, size), without the markers. Empty when the run ended
    # before printing one, such as a failed login. Only the last block counts: a
    # single vault prints one, and with BW_VAULTS each vault prints its own and
    # the run ends with one covering all of them.
    run_summary () {
        awk '/^----- Summary -----$/ { block = ""; inside = 1; next }
             /^-------------------$/ && inside { inside = 0; last = block; next }
             inside { block = block $0 "\n" }
             END { printf "%s", last }' "$run_log" 2>/dev/null
    }

    # The failure notification: the summary, if the run got that far, then the
    # end of the current run log only (never trailing lines from previous runs in
    # append mode), without the summary a second time.
    send_notification () {
        local summary tail_lines
        summary=$(run_summary)
        tail_lines=$(sed '/^----- Summary -----$/,/^-------------------$/d' "$run_log" 2>/dev/null | tail -n 15)
        if [[ -n "$summary" ]]; then
            send_message "Bitwarden/Vaultwarden Export: Failed ❌
$summary

$tail_lines"
        else
            send_message "$tail_lines"
        fi
    }

    # Resolved, not just set: a secret file that is empty or not mounted sends
    # nothing. Its warning comes from send_message, so it is not repeated here.
    run_header
    if [[ -n "$(resolve_secret NOTIFICATION_URL 2>/dev/null)" ]]; then
        notify_level_warning
    fi
    if notify_wanted start; then
        send_message "Bitwarden/Vaultwarden Export: Started"
    fi

    # Before the Infisical check below, so a failure there reads as start then fail
    # rather than as silence.
    send_ping start

    #Base Command
    local command inner_cmd
    printf -v inner_cmd '%q' "$BW_EXPORT_SCRIPT"
    if [[ -n "$RUN_AS_USER" ]]; then
        printf -v command 'su %q -c %q' "$RUN_AS_USER" "$inner_cmd"
    else
        printf -v command 'bash %q' "$BW_EXPORT_SCRIPT"
    fi
    logfile="${LOGFILE_DEFAULT:-/app/bw-export-logfile.log}"

    if [[ -n "${INFISICAL_TOKEN}" ]]; then
        # An array, so that no INFISICAL_PATH means no argument at all. A quoted
        # empty string reaches Infisical as an argument, which it rejects, so the
        # check below failed whenever INFISICAL_PATH was not set.
        local infisical_args=()
        local infisicalpath=""
        if [[ -n "${INFISICAL_PATH}" ]]; then
            infisicalpath="--path=${INFISICAL_PATH}"
            infisical_args=("$infisicalpath")
        fi
        log_info "Checking that Infisical can provide the secrets..."
        # The command run inside Infisical prints nothing: with a secret in its
        # output (the old check echoed BW_CLIENTID) the log would carry it.
        # Infisical's own output is shown only when the check fails, and its
        # errors name the token or path problem, never a secret's value.
        infisical_output=$(infisical run "${infisical_args[@]}" --command="true" 2>&1)
        returncode=$?
        if [[ "$returncode" -eq 0 ]]; then
            log_info "Infisical: secrets available."
        else
            log_error "Infisical could not provide the secrets (exit $returncode):"
            tail -n 10 <<<"$infisical_output"
            log_hint "Check INFISICAL_TOKEN and INFISICAL_PATH."
        fi
        # Stop here whether or not notifications are on: without the secrets the
        # export cannot run. The run log does not exist yet, so the message says
        # what failed and carries Infisical's own last lines.
        if [[ "$returncode" -ne "0" ]]; then
            send_message "Bitwarden/Vaultwarden Export: Failed ❌ Infisical could not provide the secrets (exit $returncode). Check INFISICAL_TOKEN and INFISICAL_PATH.
$(tail -n 5 <<<"$infisical_output")"
            exit 1
        fi
        if [[ -n "$infisicalpath" ]]; then
            printf -v command 'infisical run %q --command=%q' "$infisicalpath" "$command"
        else
            printf -v command 'infisical run --command=%q' "$command"
        fi
    fi

    if [[ -n "${FILE_LOG}" ]]; then
        logfile=$FILE_LOG
    fi

    local q_logfile q_run_log
    printf -v q_logfile '%q' "$logfile"
    printf -v q_run_log '%q' "$run_log"

    # Append only when both CRON and FILE_LOG are set, rotating at FILE_LOG_MAX_BYTES
    # (100 MiB default) so logs never grow unboundedly. When FILE_LOG is unset,
    # overwrite the container-local default log on every run.
    if [[ -n "${CRON:-}" ]] && [[ -n "${FILE_LOG:-}" ]]; then
        if [[ -f "$logfile" ]]; then
            local log_size
            log_size=$(wc -c < "$logfile" 2>/dev/null || echo 0)
            if [[ "$log_size" -ge "$FILE_LOG_MAX_BYTES" ]]; then
                mv -f "$logfile" "${logfile}.1"
            fi
        fi
        command="$command 2>&1 | tee -a $q_logfile $q_run_log"
    else
        command="$command 2>&1 | tee $q_logfile $q_run_log"
    fi
    set -o pipefail

    # "docker stop" signals PID 1, which is this script. Two things stop that from
    # reaching the export: a command run in the foreground blocks the trap until it
    # returns, and "su" answers SIGTERM by killing its child outright rather than
    # passing it on. So run the pipeline in the background and signal the export
    # directly, giving it the chance to log out of the Bitwarden CLI on its way out.
    # Invoked from the traps below, which shellcheck cannot see: older versions call
    # it unreachable (SC2317), newer ones call it uninvoked (SC2329).
    # shellcheck disable=SC2329,SC2317
    forward_signal() {
        # Only "no process matched" is expected on stderr here, never a missing pkill:
        # that is checked once below, so this stays quiet.
        pkill -"$1" -f "$BW_EXPORT_SCRIPT" 2>/dev/null
    }
    if command -v pkill >/dev/null 2>&1; then
        trap 'forward_signal TERM' TERM
        trap 'forward_signal INT' INT
    else
        # Say so rather than degrade quietly: without this the export is killed
        # outright and leaves a logged-in CLI session for the next run to clean up.
        log_warn "pkill (procps) not found. A container stop will not reach the export, so it cannot close its Bitwarden CLI session."
        log_hint "Install procps in the image."
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
    log_info "Run finished with exit code $return."

    if [[ "$return" -ne "0" ]]; then
        send_notification
    else
        local summary
        summary=$(run_summary)
        if notify_wanted success; then
            send_message "Bitwarden/Vaultwarden Export: Successfully completed ✅${summary:+
$summary}"
        fi
    fi

    # Report what the export actually did. Without this the container always exited
    # 0, so "restart: on-failure", cron and every orchestrator saw a broken backup
    # as a successful one.
    exit "$return"
}

if [[ "${1:-}" == "--run-once" ]]; then
    # Acquire the lock inside the runner itself (rather than wrapping with a
    # parent flock process) so supercronic signals this process directly on stop.
    if [[ -n "${CRON:-}" ]]; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            log_warn "Another export is already running; skipping this scheduled run."
            exit 0
        fi
    fi
    run_once
fi

# The project's logo, once per container start (not on every scheduled run,
# which re-enters this script with --run-once and never gets here).
echo " _                                             _   ";
echo "| |____      __      _____  ___ __   ___  _ __| |_ ";
echo "| '_ \ \ /\ / /____ / _ \ \/ / '_ \ / _ \| '__| __|";
echo "| |_) \ V  V /_____|  __/>  <| |_) | (_) | |  | |_ ";
echo "|_.__/ \_/\_/       \___/_/\_\ .__/ \___/|_|   \__|";
echo "                             |_|                   ";

if [[ "$ENTRYPOINT_UID" -eq 0 ]]; then
    "$ADDUSER_BIN"
else
    # 10-adduser maps PUID/PGID onto the image's user and hands it the mounted
    # folders; both need root. Here the container's own user already decides
    # who owns the files, so the folders must simply be writable by it.
    log_info "Started as uid $ENTRYPOINT_UID (gid $(id -g)): user setup skipped. The mounted folders must be writable by this user."
    if [[ -n "${PUID:-}${PGID:-}" ]]; then
        log_warn "PUID and PGID are ignored when the container does not start as root."
        log_hint "The user it runs as (compose \"user:\") already decides who owns the files."
    fi
fi

if [[ -z "${CRON:-}" ]]; then
    run_once
fi

# Cron mode: validate the schedule first so a typo fails fast, run an initial
# backup right away, and hand PID 1 over to supercronic.
# CRON is written into a crontab line ahead of the command, so anything after
# the schedule would be run as part of it, as root: "* * * * * touch x #" passes
# supercronic's own check and runs "touch x" every minute. Only a schedule is
# let through: a macro, or 5 to 7 fields of digits, cron punctuation and the
# three-letter month and day names. supercronic then checks the schedule.
cron_field='([0-9*?#/,LW-]|JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC|SUN|MON|TUE|WED|THU|FRI|SAT)+'
cron_pattern="^(@(YEARLY|ANNUALLY|MONTHLY|WEEKLY|DAILY|MIDNIGHT|HOURLY)|${cron_field}([ ]+${cron_field}){4,6})$"
cron_value=${CRON^^}
if [[ $CRON == *$'\n'* ]] || ! [[ ${cron_value//$'\t'/ } =~ $cron_pattern ]]; then
    log_error "Invalid CRON expression: $CRON" >&2
    log_hint "Use 5 fields such as \"0 3 * * *\", or a macro such as @daily." >&2
    exit 1
fi
printf '%s bash %q --run-once\n' "$CRON" "$0" > "$CRONTAB_FILE"
if ! "$SUPERCRONIC_BIN" -test "$CRONTAB_FILE"; then
    log_error "Invalid CRON expression: $CRON" >&2
    log_hint "Use 5 fields such as \"0 3 * * *\", or a macro such as @daily." >&2
    exit 1
fi

log_info "Cron mode enabled ($CRON). Running the initial backup..."
bash "$0" --run-once &
startup_pid=$!
trap 'kill -TERM "$startup_pid" 2>/dev/null || true; wait "$startup_pid" 2>/dev/null || true; exit 143' TERM
trap 'kill -INT "$startup_pid" 2>/dev/null || true; wait "$startup_pid" 2>/dev/null || true; exit 130' INT
wait "$startup_pid" || true
trap - TERM INT

log_info "Starting the cron scheduler ($CRON). Next backups run on that schedule."
exec "$SUPERCRONIC_BIN" "$CRONTAB_FILE"
