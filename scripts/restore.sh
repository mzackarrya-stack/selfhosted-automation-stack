#!/usr/bin/env bash
# restore.sh - restore a backup made by backup.sh. Destructive, interactive on purpose.
#
# Usage:
#   restore.sh --list                         show available backups
#   restore.sh STAMP                          database + n8n data volume
#   restore.sh STAMP --db-only | --data-only
#   restore.sh STAMP --skip-safety-backup     do not snapshot the current state first
#
# STAMP is the timestamp in the file names, e.g. 20261004-031500.
# Before touching anything it takes a safety backup of the current state, so a
# restore of the wrong stamp can itself be undone with restore.sh.
set -euo pipefail

SCRIPT_NAME=restore
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() { sed -n '4,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

STAMP="" DO_DB=1 DO_DATA=1 SAFETY=1 LIST=0
while (($#)); do
    case $1 in
        --list) LIST=1 ;;
        --db-only) DO_DATA=0 ;;
        --data-only) DO_DB=0 ;;
        --skip-safety-backup) SAFETY=0 ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) STAMP=$1 ;;
    esac
    shift
done

load_env
require_cmd docker gzip tar sha256sum du

BACKUP_DIR=${BACKUP_DIR:-/var/backups/n8n-stack}
# Owner of /home/node/.n8n inside the official n8n image (user "node").
N8N_UID_GID=${N8N_UID_GID:-1000:1000}
[[ $N8N_UID_GID =~ ^[0-9]+:[0-9]+$ ]] || die "N8N_UID_GID must look like 1000:1000"

if ((LIST)); then
    printf '%-17s %-10s %-10s %s\n' STAMP DATABASE DATA CHECKSUM
    shopt -s nullglob
    for f in "$BACKUP_DIR"/n8n-db-*.dump; do
        s=${f##*/n8n-db-}
        s=${s%.dump}
        db=$(du -h "$f" | cut -f1)
        data=-
        [[ -f $BACKUP_DIR/n8n-data-$s.tar.gz ]] && data=$(du -h "$BACKUP_DIR/n8n-data-$s.tar.gz" | cut -f1)
        sum=no
        [[ -f $BACKUP_DIR/n8n-$s.sha256 ]] && sum=yes
        printf '%-17s %-10s %-10s %s\n' "$s" "$db" "$data" "$sum"
    done
    exit 0
fi

[[ -n $STAMP ]] || { usage >&2; exit 2; }
[[ $STAMP =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "STAMP must look like 20261004-031500 (see --list)"
((DO_DB || DO_DATA)) || die "--db-only and --data-only together leave nothing to restore"

DB_FILE="$BACKUP_DIR/n8n-db-$STAMP.dump"
DATA_FILE="$BACKUP_DIR/n8n-data-$STAMP.tar.gz"
SUM_FILE="$BACKUP_DIR/n8n-$STAMP.sha256"

((DO_DB)) && { [[ -f $DB_FILE ]] || die "missing $DB_FILE"; }
((DO_DATA)) && { [[ -f $DATA_FILE ]] || die "missing $DATA_FILE"; }
[[ -t 0 ]] || die "restore needs an interactive terminal; refusing to run unattended"

STEP="startup"
on_exit() {
    local rc=$?
    if ((rc != 0)); then
        log "restore FAILED at step '$STEP' (exit $rc)"
        if [[ -n ${SAFETY_STAMP:-} ]]; then
            log "the state before this restore is in backup ${SAFETY_STAMP}: $0 ${SAFETY_STAMP}"
        fi
        log "n8n may be stopped; start it again with: docker compose up -d n8n"
    fi
}
trap on_exit EXIT

STEP="verify files"
if [[ -f $SUM_FILE ]]; then
    (cd "$BACKUP_DIR" && sha256sum --check --quiet --ignore-missing "${SUM_FILE##*/}") ||
        die "checksum mismatch: these files are not the ones backup.sh wrote"
    log "checksums OK"
else
    log "WARNING: no checksum file for $STAMP, skipping checksum verification"
fi
((DO_DATA)) && gzip -t "$DATA_FILE"

STEP="start postgres"
compose up -d --wait postgres
if ((DO_DB)); then
    STEP="verify database dump"
    compose exec -T postgres pg_restore --file=/dev/null <"$DB_FILE" ||
        die "$DB_FILE is not a readable pg_dump archive"
fi

cat <<EOF

  About to restore backup ${STAMP} on $(host_label).

EOF
((DO_DB)) && echo "  - database \"${POSTGRES_DB:-n8n}\" is DROPPED and recreated from ${DB_FILE##*/}"
((DO_DATA)) && echo "  - the n8n data volume is WIPED and replaced by ${DATA_FILE##*/}"
cat <<EOF
  - n8n is stopped during the restore and started again afterwards
EOF
if ((SAFETY)); then
    echo "  - the current state is backed up first, so this can be undone"
else
    echo "  - NO safety backup (--skip-safety-backup): the current state is lost"
fi
cat <<EOF

  Credentials in the database only decrypt with the N8N_ENCRYPTION_KEY of the
  server that made the backup. Check that .env carries that key before going on.

EOF
read -r -p "  Type RESTORE to continue: " answer
[[ $answer == RESTORE ]] || die "aborted, nothing was changed"

if ((SAFETY)); then
    STEP="safety backup"
    safety=$(date '+%Y%m%d-%H%M%S')
    log "taking a safety backup of the current state as ${safety}"
    # No retention (it could delete the very backup being restored) and no off-site copy.
    BACKUP_STAMP=$safety BACKUP_SKIP_RETENTION=1 RCLONE_REMOTE='' BACKUP_NOTIFY_SUCCESS=0 \
        "$SCRIPT_DIR/backup.sh"
    SAFETY_STAMP=$safety
fi

STEP="stop n8n"
compose stop n8n

if ((DO_DB)); then
    STEP="recreate database"
    log "dropping and recreating the database"
    # Run inside the container with its own credentials. psql variables (:"db")
    # quote the identifiers; DROP DATABASE cannot run inside a transaction, and
    # statements from stdin are autocommitted one by one.
    # shellcheck disable=SC2016
    compose exec -T postgres sh -c \
        'psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -v db="$POSTGRES_DB" -v owner="$POSTGRES_USER"' <<'SQL'
DROP DATABASE IF EXISTS :"db" WITH (FORCE);
CREATE DATABASE :"db" OWNER :"owner";
SQL

    STEP="restore database"
    log "restoring ${DB_FILE##*/}"
    # One transaction: either the whole dump goes in, or nothing does.
    # shellcheck disable=SC2016
    compose exec -T postgres sh -c \
        'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --single-transaction --exit-on-error' \
        <"$DB_FILE"
fi

if ((DO_DATA)); then
    STEP="restore n8n data volume"
    log "restoring ${DATA_FILE##*/} into the n8n data volume"
    compose run --rm --no-deps -T volume-tools sh -c \
        "find /data/n8n -mindepth 1 -delete && tar -xzf - -C /data/n8n && chown -R ${N8N_UID_GID} /data/n8n" \
        <"$DATA_FILE"
fi

STEP="start n8n"
log "starting n8n and waiting for it to report healthy"
compose up -d --wait --wait-timeout 300 n8n

STEP="done"
cat <<EOF

  Restore of ${STAMP} finished and n8n reports healthy. Now check it by hand:
    1. log in to the editor (https://${N8N_HOST:-your-host}/, or the tunnel in a drill)
    2. open one credential: if it shows its fields, the encryption key matches
    3. run one workflow manually and look at the execution
EOF
if [[ -n ${SAFETY_STAMP:-} ]]; then
    echo "  To undo: $0 ${SAFETY_STAMP}"
fi
