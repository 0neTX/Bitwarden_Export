#!/usr/bin/env bash
# Runs exports against the environment tests/e2e-setup.sh built, and checks what
# actually came out. Unlike run_tests.sh this drives the real Bitwarden CLI
# against a real Vaultwarden, so it is the only thing here that notices when a
# new CLI release changes behaviour.
#
#   bash tests/e2e-setup.sh && bash tests/e2e-verify.sh
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE=(docker compose -f "$PWD/compose.test.yml" --env-file "$PWD/e2e/test.env")
NAME=bwtest-bw-export

fail() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "==> $*"; }

# Waits for the container to exit; leaves its status in $status.
wait_exit() {
    local i
    for ((i = 0; i < 180; i++)); do
        status=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)
        [ "$status" = exited ] && return 0
        sleep 2
    done
    return 1
}

# Waits for a line to appear in the log written since $1 lines.
wait_for_log() {
    local since=$1 pattern=$2 i
    for ((i = 0; i < 240; i++)); do
        if docker logs "$NAME" 2>&1 | tail -n +"$((since + 1))" | grep -q "$pattern"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

note "clean run"
rm -rf e2e/data/* e2e/att/*
docker rm -f "$NAME" >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d bw-export >/dev/null
wait_exit || fail "the export never finished"

code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
docker logs "$NAME" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'

[ "$code" = 0 ] || fail "container exited $code, expected 0"
compgen -G 'e2e/data/*/bitwarden_encrypted_export_*.json'     >/dev/null || fail "no personal vault export"
compgen -G 'e2e/data/*/bitwarden_encrypted_org_export_*.json' >/dev/null || fail "no organization export"
compgen -G 'e2e/att/*/*/*'                                    >/dev/null || fail "no attachment downloaded"
note "clean run OK: personal export, organization export and attachment present"

# Issue #21: the bug only appears when the SAME container runs again after a
# dirty stop, so kill it mid-export and restart it.
note "issue #21 recovery"
before=$(docker logs "$NAME" 2>&1 | wc -l)
docker start "$NAME" >/dev/null
wait_for_log "$before" 'Vault unlocked' || fail "second run never unlocked the vault"
sleep 1
docker kill "$NAME" >/dev/null
sleep 2

before=$(docker logs "$NAME" 2>&1 | wc -l)
docker start "$NAME" >/dev/null
wait_exit || fail "the recovery run never finished"

recovery=$(docker logs "$NAME" 2>&1 | tail -n +"$((before + 1))" | sed 's/\x1b\[[0-9;]*m//g')
code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME")
printf '%s\n' "$recovery"

grep -q 'Existing session detected' <<<"$recovery" \
    || fail "the leftover session was not detected, so #21 is not covered by this run"
[ "$code" = 0 ] || fail "the recovery run exited $code, expected 0"
note "recovery OK: stale session detected and cleared"

echo
echo "e2e passed"
