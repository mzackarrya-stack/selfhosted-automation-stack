#!/usr/bin/env bash
# backup.sh - PostgreSQL dump + n8n data volume, verified, rotated, optionally off-site.
#
#   n8n-db-<stamp>.dump        pg_dump custom format (compressed, restorable with pg_restore)
#   n8n-data-<stamp>.tar.gz    the n8n data volume (/home/node/.n8n)
#   n8n-<stamp>.sha256         checksums of both
#
# Each file is written as *.partial, verified, then renamed: a file without the
# suffix has been read back successfully. Old backups are deleted only after the
# new one is complete, so a broken backup job cannot rotate away the last good copies.
# Any failure exits non-zero and sends a Telegram alert naming the failed step.
#
# Usage: backup.sh        (run as root from cron, see crontab.example)
# Env:   everything comes from .env. restore.sh additionally sets BACKUP_STAMP
#        (fixed name) and BACKUP_SKIP_RETENTION=1 for its safety backup.
set -euo pipefail

SCRIPT_NAME=backup
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_env
require_cmd docker gzip tar sha256sum find flock df awk hostname

BACKUP_DIR=${BACKUP_DIR:-/var/backups/n8n-stack}
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-14}
MIN_FREE_MB=${BACKUP_MIN_FREE_MB:-1024}
STAMP=${BACKUP_STAMP:-$(date '+%Y%m%d-%H%M%S')}
DB_FILE="$BACKUP_DIR/n8n-db-$STAMP.dump"
DATA_FILE="$BACKUP_DIR/n8n-data-$STAMP.tar.gz"
SUM_FILE="$BACKUP_DIR/n8n-$STAMP.sha256"
STEP=startup

[[ $STAMP =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "BACKUP_STAMP must look like 20261004-031500"
[[ $RETENTION_DAYS =~ ^[1-9][0-9]*$ ]] || die "BACKUP_RETENTION_DAYS must be a whole number >= 1"
[[ $MIN_FREE_MB =~ ^[0-9]+$ ]] || die "BACKUP_MIN_FREE_MB must be a whole number"

on_exit() {
    local rc=$?
    rm -f "$DB_FILE.partial" "$DATA_FILE.partial"
    if ((rc != 0)); then
        log "backup FAILED at step '$STEP' (exit $rc)"
        telegram_send "$(printf '[n8n-stack] BACKUP FAILED\nhost: %s\nstep: %s\nexit code: %s\nThe previous backups were left untouched.' \
            "$(host_label)" "$STEP" "$rc")" || true
    fi
}
trap on_exit EXIT

STEP="preflight"
umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

exec 9>"$BACKUP_DIR/.backup.lock"
flock -n 9 || die "another backup is already running"

free_mb=$(df -m --output=avail "$BACKUP_DIR" | awk 'NR == 2 { print $1 }')
((free_mb >= MIN_FREE_MB)) ||
    die "only ${free_mb} MB free in $BACKUP_DIR, need at least ${MIN_FREE_MB} MB (BACKUP_MIN_FREE_MB)"

pg_container=$(compose ps -q postgres) || die "docker compose failed (see the error above)"
[[ -n $pg_container ]] || die "the postgres container is not running"

# Leftovers from a run that was killed (power loss, OOM) before its trap could clean up.
find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.partial' -mmin +60 -delete

STEP="dump database"
log "dumping PostgreSQL -> $DB_FILE"
# The server's own pg_dump, so client and server versions always match.
# Single quotes: the variables are expanded inside the container, from its own env.
# shellcheck disable=SC2016
compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' \
    >"$DB_FILE.partial"
[[ -s $DB_FILE.partial ]] || die "pg_dump produced an empty file"

STEP="verify database dump"
# Convert the whole archive back to SQL and throw the SQL away. Unlike --list, which
# only reads the table of contents at the start, this decompresses every data block:
# a truncated or corrupt dump fails here, tonight, not on the day you need it.
compose exec -T postgres pg_restore --file=/dev/null <"$DB_FILE.partial"
mv "$DB_FILE.partial" "$DB_FILE"

STEP="archive n8n data volume"
log "archiving the n8n data volume -> $DATA_FILE"
compose run --rm --no-deps -T volume-tools tar -C /data/n8n -czf - . >"$DATA_FILE.partial"

STEP="verify n8n archive"
gzip -t "$DATA_FILE.partial"
tar -tzf "$DATA_FILE.partial" >/dev/null
mv "$DATA_FILE.partial" "$DATA_FILE"

STEP="checksums"
(cd "$BACKUP_DIR" && sha256sum "${DB_FILE##*/}" "${DATA_FILE##*/}" >"${SUM_FILE##*/}")

if [[ -n ${RCLONE_REMOTE:-} ]]; then
    STEP="off-site copy"
    require_cmd rclone
    log "copying to $RCLONE_REMOTE"
    rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE" --include "n8n-*-${STAMP}.*" --include "n8n-${STAMP}.sha256"
    # Compare what landed with what was sent (size, and hash where the remote supports it).
    rclone check "$BACKUP_DIR" "$RCLONE_REMOTE" --one-way --include "n8n-*-${STAMP}.*" --include "n8n-${STAMP}.sha256"

    remote_days=${RCLONE_RETENTION_DAYS:-30}
    if [[ ${BACKUP_SKIP_RETENTION:-0} != 1 && $remote_days =~ ^[1-9][0-9]*$ ]]; then
        STEP="off-site retention"
        rclone delete "$RCLONE_REMOTE" --include 'n8n-*' --min-age "${remote_days}d"
    fi
fi

if [[ ${BACKUP_SKIP_RETENTION:-0} != 1 ]]; then
    STEP="local retention"
    deleted=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'n8n-*' \
        -mmin +"$((RETENTION_DAYS * 24 * 60))" -print -delete | wc -l)
    log "retention: deleted ${deleted} file(s) older than ${RETENTION_DAYS} days"
fi

STEP="done"
db_size=$(du -h "$DB_FILE" | cut -f1)
data_size=$(du -h "$DATA_FILE" | cut -f1)
log "backup $STAMP complete: database ${db_size}, data ${data_size}"
if [[ ${BACKUP_NOTIFY_SUCCESS:-0} == 1 ]]; then
    telegram_send "$(printf '[n8n-stack] backup OK\nhost: %s\nstamp: %s\ndatabase %s, data %s' \
        "$(host_label)" "$STAMP" "$db_size" "$data_size")" || true
fi
