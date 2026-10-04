#!/bin/sh
# Entry point of the nginx container (POSIX sh, nginx:alpine image).
#
#  1. Renders the config for the current certificate state:
#       no certificate yet -> HTTP only: ACME challenges, plus a 503 saying why
#       certificate        -> HTTP redirect + HTTPS reverse proxy to n8n
#  2. Starts nginx in the foreground.
#  3. Watches the certificate file. When it appears (first issuance) or changes
#     (renewal), re-renders, runs `nginx -t`, and reloads. A certificate nginx
#     rejects never replaces a working config.
#
# This is what lets certbot run in its own container without a Docker socket.
set -eu

: "${N8N_HOST:?N8N_HOST must be set}"

TEMPLATES=/opt/nginx/templates
CONF_DIR=/etc/nginx/conf.d
CERT="/etc/letsencrypt/live/${N8N_HOST}/fullchain.pem"
KEY="/etc/letsencrypt/live/${N8N_HOST}/privkey.pem"
POLL="${NGINX_CERT_POLL_SECONDS:-60}"

log() { echo "[nginx-start] $*"; }

have_cert() { [ -s "$CERT" ] && [ -s "$KEY" ]; }

fingerprint() {
    if have_cert; then cksum < "$CERT"; else echo none; fi
}

# render tls|http-only
# HTTP_ACTION is nginx config text: its quotes are meant to reach nginx literally.
# shellcheck disable=SC2089,SC2090
render() {
    rm -f "$CONF_DIR"/*.conf
    if [ "$1" = tls ]; then
        # shellcheck disable=SC2016  # $host and $request_uri are nginx variables
        HTTP_ACTION='return 301 https://$host$request_uri;'
    else
        # Deliberately vague for the public; the operator reads `docker compose logs certbot`.
        HTTP_ACTION='default_type text/plain; return 503 "TLS certificate not issued yet. Try again in a few minutes.\n";'
    fi
    export N8N_HOST HTTP_ACTION
    # shellcheck disable=SC2016  # envsubst wants the literal variable names
    envsubst '${N8N_HOST} ${HTTP_ACTION}' < "$TEMPLATES/http.conf.template" > "$CONF_DIR/10-http.conf"
    if [ "$1" = tls ]; then
        # shellcheck disable=SC2016
        envsubst '${N8N_HOST}' < "$TEMPLATES/https.conf.template" > "$CONF_DIR/20-https.conf"
    fi
}

# Startup: TLS when possible, otherwise HTTP only so ACME challenges can be answered.
configure_at_startup() {
    if have_cert; then
        render tls
        if nginx -t -q; then
            log "config: HTTPS for ${N8N_HOST}"
            return 0
        fi
        log "WARNING: a certificate exists but nginx rejects it; serving HTTP only"
    fi
    render http-only
    nginx -t -q
    log "config: HTTP only, waiting for a certificate for ${N8N_HOST}"
}

# Runtime: switch to the new certificate only if nginx accepts it.
reload_for_new_cert() {
    saved=$(mktemp -d)
    cp "$CONF_DIR"/*.conf "$saved"/
    if have_cert && render tls && nginx -t -q; then
        nginx -s reload
        log "certificate changed on disk: config re-rendered, nginx reloaded"
        rm -rf "$saved"
        return 0
    fi
    log "ERROR: new certificate rejected by nginx -t; keeping the previous config"
    rm -f "$CONF_DIR"/*.conf
    cp "$saved"/*.conf "$CONF_DIR"/
    rm -rf "$saved"
    return 1
}

watch_cert() {
    set +e   # a failed iteration must not kill the watcher silently
    last=$(fingerprint)
    while :; do
        sleep "$POLL"
        current=$(fingerprint)
        if [ "$current" != "$last" ] && reload_for_new_cert; then
            last=$current
        fi
    done
}

configure_at_startup
watch_cert &
exec nginx -g 'daemon off;'
