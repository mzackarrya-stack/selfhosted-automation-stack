# shellcheck shell=bash
# Shared helpers for backup.sh, restore.sh and healthcheck.sh. Sourced, never executed.

STACK_DIR="${STACK_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENV_FILE="${ENV_FILE:-$STACK_DIR/.env}"

log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${SCRIPT_NAME:-stack}" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

# Reads KEY=VALUE lines from the .env file without executing it (no `source`):
# a .env is configuration, and sourcing it would run any command written in it.
# Variables already present in the environment win, as they do in docker compose.
load_env() {
    local file=${1:-$ENV_FILE} line key val
    local re_skip='^[[:space:]]*(#|$)'
    local re_pair='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
    local re_dq='^"(.*)"$' re_sq="^'(.*)'$"

    [[ -r $file ]] || die "cannot read $file (copy .env.example to .env and fill it in)"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ $re_skip ]] && continue
        [[ $line =~ $re_pair ]] || continue
        key=${BASH_REMATCH[2]}
        val=${BASH_REMATCH[3]}
        if [[ $val =~ $re_dq || $val =~ $re_sq ]]; then
            val=${BASH_REMATCH[1]}
        else
            val=${val%%[[:space:]]#*}                 # unquoted: strip " # comment"
            val=${val%"${val##*[![:space:]]}"}        # and trailing whitespace
        fi
        if [[ -z ${!key+set} ]]; then
            printf -v "$key" '%s' "$val"
            export "${key?}"
        fi
    done <"$file"
}

# docker compose pinned to this checkout, whatever the current directory is.
# COMPOSE_FILES (space-separated, relative to the repo) adds override files,
# e.g. COMPOSE_FILES="docker-compose.yml docker-compose.drill.yml".
compose() {
    local files=() args=() f
    read -r -a files <<<"${COMPOSE_FILES:-docker-compose.yml}"
    for f in "${files[@]}"; do
        args+=(-f "$STACK_DIR/$f")
    done
    docker compose --project-directory "$STACK_DIR" --env-file "$ENV_FILE" "${args[@]}" "$@"
}

telegram_enabled() {
    [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]]
}

# telegram_send TEXT -> 0 sent (or alerts not configured), 1 the API call failed.
telegram_send() {
    local text=$1
    if ! telegram_enabled; then
        log "Telegram not configured, alert printed only: ${text//$'\n'/ | }"
        return 0
    fi
    # The bot token goes to curl through a config on stdin, so it never shows up
    # in the process list (`ps aux`) the way a URL argument would.
    if printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
        curl --silent --show-error --fail --max-time 15 --retry 2 --config - \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${text}" \
            --data-urlencode "disable_web_page_preview=true" >/dev/null; then
        return 0
    fi
    log "WARNING: Telegram API call failed"
    return 1
}

host_label() {
    printf '%s (%s)' "${N8N_HOST:-n8n-stack}" "$(hostname)"
}
