# Log lines for every script in the image. Sourced, never run.
# shellcheck shell=bash
#
# One event per line, "<date> <time> LEVEL: message", with no colour codes: the
# same lines end up in FILE_LOG, in the failure notification and in support
# requests, where escape codes are noise.
#
#   INFO     what is happening
#   WARNING  something to look at; the run goes on
#   ERROR    something failed
#   HINT     what to do about the error or warning just above
#
# Nothing secret is ever logged: no password, key, token or URL with
# credentials, and nothing from inside the vault (item, folder, organization or
# attachment names). Configuration is described by where it comes from, not by
# its value.

log()       { printf '%s %s: %s\n' "$(date '+%F %T')" "$1" "$2"; }
log_info()  { log INFO "$*"; }
log_warn()  { log WARNING "$*"; }
log_error() { log ERROR "$*"; }
log_hint()  { log HINT "$*"; }

# Where a secret variable's value comes from, never the value: "set",
# "from a file", or "not set". NAME and NAME_FILE as in secrets.sh.
secret_source() {
    local name=$1 file_name="${1}_FILE"
    if [[ -n ${!file_name:-} ]]; then
        echo "from a file"
    elif [[ -n ${!name:-} ]]; then
        if [[ ${!name} == /run/secrets/* ]]; then echo "from a Docker secret"; else echo "set"; fi
    else
        echo "not set"
    fi
}

# What kind of server a URL is, without the URL itself: a self-hosted server's
# address says where someone's vault lives, which a log pasted into an issue
# should not. Vaultwarden answers /api/version, so its version is added when it
# can be read; it is what most compatibility problems come down to.
#   $1  BW_URL_SERVER, empty for bitwarden.com
server_label() {
    local url=${1%/} version="" cacert=()
    case $url in
        "" | https://vault.bitwarden.com | https://bitwarden.com) echo "bitwarden.com"; return ;;
        https://vault.bitwarden.eu | https://bitwarden.eu) echo "bitwarden.eu"; return ;;
    esac
    [[ -n ${NODE_EXTRA_CA_CERTS:-} ]] && cacert=(--cacert "$NODE_EXTRA_CA_CERTS")
    version=$(curl -fsS --max-time 5 "${cacert[@]}" "$url/api/version" 2>/dev/null | tr -d '"[:space:]')
    if [[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
        echo "self-hosted, Vaultwarden $version"
    elif [[ $url == https://* ]]; then
        echo "self-hosted, version unknown"
    else
        echo "self-hosted, not HTTPS"
    fi
}
