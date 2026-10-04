#!/bin/sh
# Entry point of the certbot container (POSIX sh, certbot/certbot image).
#
# One command covers both cases: `certonly --keep-until-expiring` obtains the
# certificate when none exists and is a no-op until renewal is due. Challenges are
# answered through the webroot that nginx serves at /.well-known/acme-challenge/.
# nginx notices the new files by itself (see nginx/start.sh), so this container
# needs no Docker socket and never touches nginx.
set -u

: "${N8N_HOST:?N8N_HOST must be set}"

# Twice a day when healthy. After a failure, retry every 30 min: fast enough for a
# first deployment where DNS is still propagating, slow enough to stay far below
# Let's Encrypt's limit on failed validations per hostname per hour.
CHECK_EVERY="${CERTBOT_CHECK_INTERVAL_SECONDS:-43200}"
RETRY_EVERY="${CERTBOT_RETRY_INTERVAL_SECONDS:-1800}"

set -- certonly --webroot --webroot-path /var/www/certbot \
    --cert-name "$N8N_HOST" --domain "$N8N_HOST" \
    --non-interactive --agree-tos --keep-until-expiring

if [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
    set -- "$@" --email "$LETSENCRYPT_EMAIL" --no-eff-email
else
    set -- "$@" --register-unsafely-without-email
fi

if [ "${LETSENCRYPT_STAGING:-0}" = "1" ]; then
    echo "[certbot-loop] using the Let's Encrypt STAGING CA: browsers will not trust this certificate"
    set -- "$@" --staging
fi

trap 'echo "[certbot-loop] stopping"; exit 0' TERM INT

while :; do
    if certbot "$@"; then
        wait_for=$CHECK_EVERY
    else
        echo "[certbot-loop] ERROR: certificate request failed (DNS for ${N8N_HOST} pointing here? port 80 open?); retrying in ${RETRY_EVERY}s"
        wait_for=$RETRY_EVERY
    fi
    # Background sleep + wait, so a stop signal is handled immediately.
    sleep "$wait_for" &
    wait $!
done
