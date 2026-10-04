#!/usr/bin/env bash
# healthcheck.sh - checks the stack every few minutes; alerts on Telegram only on change.
#
# Checks: every container running (and healthy, where it has a healthcheck);
# https://N8N_HOST/healthz/readiness answers 200 through nginx, TLS and n8n down
# to the database; disk and inode usage; days left on the certificate actually
# served on :443 (not the file on disk); age of the newest complete backup set.
#
# Alerting: a check must fail HEALTH_FAIL_THRESHOLD runs in a row before it alerts,
# then it alerts once, sends one RECOVERED message when it passes again, and repeats
# itself every HEALTH_RENOTIFY_HOURS while it stays broken (0 = never). All changes
# from one run go out as a single message. State lives in HEALTH_STATE_FILE; if
# Telegram cannot be reached, the state is not saved and the next run tries again.
#
# Usage: healthcheck.sh [--quiet] [--test-alert]
#   --quiet       print only alerts and failures (for cron)
#   --test-alert  send a test message and exit: an alert path that has never fired
#                 has not been tested
# Exit:  0 all checks pass, 1 at least one check is failing.
set -euo pipefail

SCRIPT_NAME=health
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUIET=0 TEST_ALERT=0
while (($#)); do
    case $1 in
        --quiet) QUIET=1 ;;
        --test-alert) TEST_ALERT=1 ;;
        -h | --help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

load_env
require_cmd docker curl openssl df flock date awk find timeout hostname

: "${N8N_HOST:?N8N_HOST is not set in .env}"
STATE_FILE=${HEALTH_STATE_FILE:-/var/lib/n8n-stack/health.state}
SERVICES=${HEALTH_SERVICES:-postgres n8n nginx certbot}
URL=${HEALTH_URL:-https://${N8N_HOST}/healthz/readiness}
DISK_MAX=${HEALTH_DISK_MAX_PCT:-85}
DISK_PATHS=${HEALTH_DISK_PATHS:-/ /var/lib/docker}
CERT_MIN_DAYS=${HEALTH_CERT_MIN_DAYS:-14}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/n8n-stack}
BACKUP_MAX_AGE_H=${HEALTH_BACKUP_MAX_AGE_HOURS:-26}
FAIL_THRESHOLD=${HEALTH_FAIL_THRESHOLD:-2}
RENOTIFY_H=${HEALTH_RENOTIFY_HOURS:-24}

for n in DISK_MAX CERT_MIN_DAYS BACKUP_MAX_AGE_H FAIL_THRESHOLD RENOTIFY_H; do
    [[ ${!n} =~ ^[0-9]+$ ]] || die "$n must be a whole number (got '${!n}')"
done
((FAIL_THRESHOLD >= 1)) || FAIL_THRESHOLD=1

if ((TEST_ALERT)); then
    telegram_enabled || die "TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set in .env"
    telegram_send "$(printf '[n8n-stack] test alert from %s\nIf you can read this, failures will reach you.' "$(host_label)")" ||
        die "test alert could NOT be delivered"
    log "test alert delivered"
    exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")"
exec 9>"$STATE_FILE.lock"
flock -n 9 || { log "previous run still in progress, skipping"; exit 0; }

declare -a ORDER=()
declare -A STATUS=() DETAIL=()

record() { # record NAME OK|FAIL DETAIL
    ORDER+=("$1")
    STATUS[$1]=$2
    DETAIL[$1]=$3
    if ((!QUIET)) || [[ $2 != OK ]]; then
        log "$(printf '%-24s %-4s %s' "$1" "$2" "$3")"
    fi
}

check_containers() {
    local svc cid state health services
    read -r -a services <<<"$SERVICES"
    for svc in "${services[@]}"; do
        cid=$(compose ps -q "$svc" 2>/dev/null || true)
        if [[ -z $cid ]]; then
            record "container:$svc" FAIL "not running"
            continue
        fi
        read -r state health < <(docker inspect \
            -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$cid" 2>/dev/null || echo "unknown unknown")
        if [[ $state == running && ($health == healthy || $health == none) ]]; then
            record "container:$svc" OK "$state, health: $health"
        else
            record "container:$svc" FAIL "$state, health: $health"
        fi
    done
}

check_https() {
    local errf code err
    errf=$(mktemp)
    code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --max-time 15 "$URL" 2>"$errf") || true
    err=$(head -c 200 "$errf")
    rm -f "$errf"
    if [[ $code == 200 ]]; then
        record "https" OK "$URL -> 200"
    else
        record "https" FAIL "$URL -> ${code:-000} ${err}"
    fi
}

check_cert() {
    local end end_s days
    # The certificate nginx is actually serving. A renewed file on disk that nginx
    # never loaded still expires in the browser; checking the file would say "fine".
    end=$(timeout 20 openssl s_client -connect "${N8N_HOST}:443" -servername "$N8N_HOST" </dev/null 2>/dev/null |
        openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2) || true
    if [[ -z $end ]] || ! end_s=$(date -d "$end" +%s 2>/dev/null); then
        record "certificate" FAIL "could not read the certificate served on ${N8N_HOST}:443"
        return
    fi
    days=$(((end_s - $(date +%s)) / 86400))
    if ((days < CERT_MIN_DAYS)); then
        record "certificate" FAIL "expires in ${days} days (${end}); is the certbot container renewing?"
    else
        record "certificate" OK "${days} days left"
    fi
}

check_disk() {
    local p mnt pct ipct paths
    local -A seen=()
    read -r -a paths <<<"$DISK_PATHS"
    for p in "${paths[@]}"; do
        [[ -e $p ]] || continue
        # Named columns, mount point last: immune to spaces in the filesystem name.
        read -r pct ipct mnt < <(df --output=pcent,ipcent,target "$p" | awk 'NR == 2 { gsub("%", ""); print }')
        [[ -n ${mnt:-} && -z ${seen[$mnt]:-} ]] || continue
        seen[$mnt]=1
        [[ $pct =~ ^[0-9]+$ ]] || pct=0
        [[ $ipct =~ ^[0-9]+$ ]] || ipct=0 # some filesystems report "-" for inodes
        if ((pct >= DISK_MAX || ipct >= DISK_MAX)); then
            record "disk:$mnt" FAIL "${pct}% space, ${ipct}% inodes used (limit ${DISK_MAX}%)"
        else
            record "disk:$mnt" OK "${pct}% space, ${ipct}% inodes used"
        fi
    done
}

check_backup() {
    local newest age_h
    # The .sha256 file is written last, once both the dump and the volume archive
    # are verified: it marks a complete backup set, not half of one.
    # `|| true`: a missing BACKUP_DIR must report a failed check, not abort the script.
    newest=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'n8n-*.sha256' -printf '%T@\n' 2>/dev/null |
        sort -n | tail -n 1) || true
    if [[ -z $newest ]]; then
        record "backup" FAIL "no complete backup found in $BACKUP_DIR"
        return
    fi
    age_h=$((($(date +%s) - ${newest%.*}) / 3600))
    if ((age_h > BACKUP_MAX_AGE_H)); then
        record "backup" FAIL "newest complete backup is ${age_h} h old (limit ${BACKUP_MAX_AGE_H} h); is the cron job running?"
    else
        record "backup" OK "newest complete backup is ${age_h} h old"
    fi
}

fmt_duration() {
    local s=$1
    if ((s >= 86400)); then
        printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
    elif ((s >= 3600)); then
        printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
    else
        printf '%dm' $((s / 60))
    fi
}

check_containers
check_https
check_cert
check_disk
check_backup

# ----------------------------------------------------------- state machine
# State file, one line per check: name <TAB> OK|FAIL <TAB> consecutive_fails <TAB>
# first_fail_epoch <TAB> last_alert_epoch. "FAIL" means "an alert has been sent".
declare -A P_STATE=() P_FAILS=() P_SINCE=() P_LAST=()
if [[ -f $STATE_FILE ]]; then
    while IFS=$'\t' read -r name st fl since last; do
        [[ -n $name ]] || continue
        P_STATE[$name]=$st P_FAILS[$name]=$fl P_SINCE[$name]=$since P_LAST[$name]=$last
    done <"$STATE_FILE"
fi

now=$(date +%s)
messages=()
new_state=""
failing=0

for name in "${ORDER[@]}"; do
    prev=${P_STATE[$name]:-OK}
    fails=${P_FAILS[$name]:-0}
    since=${P_SINCE[$name]:-$now}
    last=${P_LAST[$name]:-0}
    [[ $fails =~ ^[0-9]+$ ]] || fails=0
    [[ $since =~ ^[0-9]+$ ]] || since=$now
    [[ $last =~ ^[0-9]+$ ]] || last=0

    if [[ ${STATUS[$name]} == OK ]]; then
        if [[ $prev == FAIL ]]; then
            messages+=("RECOVERED  $name (was failing for $(fmt_duration $((now - since))))")
        fi
        state=OK fails=0 since=$now last=0
    else
        failing=$((failing + 1))
        fails=$((fails + 1))
        ((fails == 1)) && since=$now
        if [[ $prev == FAIL ]]; then
            state=FAIL
            if ((RENOTIFY_H > 0 && now - last >= RENOTIFY_H * 3600)); then
                messages+=("STILL FAILING  $name for $(fmt_duration $((now - since))): ${DETAIL[$name]}")
                last=$now
            fi
        elif ((fails >= FAIL_THRESHOLD)); then
            state=FAIL last=$now
            messages+=("FAIL  $name: ${DETAIL[$name]}")
        else
            state=OK # failing, but not long enough to alert yet
        fi
    fi
    new_state+="$(printf '%s\t%s\t%s\t%s\t%s' "$name" "$state" "$fails" "$since" "$last")"$'\n'
done

if ((${#messages[@]})); then
    text="[n8n-stack] $(host_label)"
    for m in "${messages[@]}"; do
        text+=$'\n'"$m"
    done
    text+=$'\n'"(${failing} of ${#ORDER[@]} checks failing)"
    log "sending alert: ${#messages[@]} change(s)"
    if ! telegram_send "$text"; then
        log "alert not delivered; state not saved, the next run will retry"
        exit 1
    fi
fi

tmp_state=$(mktemp "$STATE_FILE.XXXXXX")
printf '%s' "$new_state" >"$tmp_state"
mv "$tmp_state" "$STATE_FILE"

((failing == 0)) || exit 1
((QUIET)) || log "all ${#ORDER[@]} checks pass"
