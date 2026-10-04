# selfhosted-automation-stack

n8n and PostgreSQL on a single Ubuntu VPS, behind Nginx with automatic Let's Encrypt
certificates, plus the three scripts that keep it alive unattended: nightly backups,
health checks that alert on Telegram, and a hardening pass for the server itself.

Getting n8n to start is twenty lines of YAML. Keeping it running for a year without
looking at it is the rest of this repository. Most of what is here exists because of
one of four ways a self-hosted stack fails quietly, described below.

This is a template to read and adapt, not a managed service. Everything was
syntax-checked and partly exercised locally (see [What was verified](#what-was-verified));
it has not been run end to end in this repository, because Docker was not available
where it was written.

## Architecture

```
                         Internet
                            |
                            |  80, 443: the only published ports
                 +----------v-----------+        +-----------------+
                 |        nginx         |        |     certbot     |
                 |  TLS, headers,       |<------>|  issue / renew  |
                 |  WebSocket proxy     | certs  |  (webroot)      |
                 +----------+-----------+ volume +-----------------+
                            |  edge network
                 +----------v-----------+
                 |         n8n          |  no published port
                 +----------+-----------+
                            |  backend network: internal, no route out
                 +----------v-----------+
                 |     PostgreSQL 17    |
                 +----------------------+

  host cron:  backup.sh       nightly   -> /var/backups/n8n-stack -> rclone (optional)
              healthcheck.sh  every 5m  -> Telegram, only when something changes
```

## Quick start

1. **A VPS with Ubuntu 22.04 or 24.04**, a DNS `A` record (and `AAAA` if it has IPv6)
   for your hostname pointing at it, and Docker Engine with the Compose plugin
   v2.20 or later ([official instructions](https://docs.docker.com/engine/install/ubuntu/)).

2. **Harden the server first**, from a session where SSH key login already works:

   ```bash
   sudo git clone https://github.com/<you>/selfhosted-automation-stack /opt/n8n-stack
   cd /opt/n8n-stack
   sudo ./scripts/harden-ubuntu.sh --dry-run   # read what it will do
   sudo ./scripts/harden-ubuntu.sh
   ```

3. **Configure:**

   ```bash
   sudo cp .env.example .env && sudo chmod 600 .env
   openssl rand -hex 32   # run twice: POSTGRES_PASSWORD and N8N_ENCRYPTION_KEY
   sudo nano .env         # N8N_HOST, the two secrets, Telegram bot token + chat id
   ```

   Put `N8N_ENCRYPTION_KEY` in your password manager now. Without it, a database
   backup restores workflows whose credentials can no longer be decrypted.

4. **Start it** and watch the certificate arrive:

   ```bash
   sudo docker compose up -d
   sudo docker compose logs -f certbot nginx   # wait for "config: HTTPS for ..."
   ```

   Then open `https://<your host>/` and create the owner account (enable 2FA on it).

5. **Prove the safety nets work** before trusting them:

   ```bash
   sudo ./scripts/backup.sh                    # first backup, verified
   sudo ./scripts/healthcheck.sh --test-alert  # a Telegram message must arrive
   sudo ./scripts/healthcheck.sh               # every check should say OK
   ```

6. **Schedule them:**

   ```bash
   sudo mkdir -p /var/log/n8n-stack
   sudo cp crontab.example /etc/cron.d/n8n-stack
   sudo cp logrotate.example /etc/logrotate.d/n8n-stack
   ```

Trying it on a hostname for the first time? Set `LETSENCRYPT_STAGING=1` until the
certificate step works, so mistakes do not burn the production rate limit. Staging
certificates are untrusted, so the health check reports HTTPS as failing; that is
expected. To switch to a real certificate, delete the staging one and restart certbot:
`docker compose exec certbot certbot delete --cert-name <host> --non-interactive`,
set `LETSENCRYPT_STAGING=0`, then `docker compose up -d certbot`.

## What each piece does

| File | What it does |
|---|---|
| `docker-compose.yml` | Four services, plus a tools container the scripts use to read and write the n8n volume. Only nginx publishes ports. PostgreSQL sits on an `internal` network with no route out. Pinned images, healthchecks, memory limits, `restart: unless-stopped`, log rotation, `no-new-privileges`, all capabilities dropped for n8n. Secrets are required (`${VAR:?}`): Compose refuses to start with them empty. |
| `nginx/start.sh` | Container entry point. Serves HTTP only (ACME challenges) until a certificate exists, then switches to HTTPS. Polls the certificate and reloads nginx when it changes, after `nginx -t`. A certificate nginx rejects never replaces a working config. |
| `nginx/templates/` | The actual Nginx config: TLS 1.2/1.3, HSTS, WebSocket upgrade for the editor, 16 MiB body limit matching n8n, 444 for unknown hostnames, TLS handshake refused for unknown SNI. |
| `certbot/loop.sh` | Container entry point. `certonly --keep-until-expiring` twice a day: obtains the certificate the first time, renews when due, retries every 30 minutes after a failure. |
| `scripts/backup.sh` | `pg_dump` (custom format) plus a tarball of the n8n data volume. Each file is verified before it gets its final name, checksummed, optionally copied off-site with rclone and checked there. Retention runs only after success. Any failure exits non-zero and alerts on Telegram with the step that failed. |
| `scripts/restore.sh` | Lists backups, verifies checksums and archives, takes a safety backup of the current state, then asks you to type `RESTORE`. Drops and recreates the database, restores in a single transaction, replaces the data volume, waits for n8n to report healthy. Refuses to run without a terminal. |
| `scripts/healthcheck.sh` | Containers running and healthy; `https://<host>/healthz/readiness` returns 200 (nginx, TLS, n8n and the database in one request); disk and inode usage; days left on the certificate actually served; age of the newest complete backup set. Alerts on change only. |
| `scripts/harden-ubuntu.sh` | ufw, fail2ban, unattended upgrades, key-only SSH (only if a key exists), swap. Idempotent, prints every command, asks before risky steps, `--dry-run`. Details in [docs/HARDENING.md](docs/HARDENING.md). |
| `docker-compose.drill.yml` | Override for restore drills on a scratch machine: n8n without internet access, reached through a loopback-only proxy. |

## Why plain Nginx + certbot, and not nginx-proxy + acme-companion

`nginxproxy/nginx-proxy` with `acme-companion` is the popular choice, and it is less
code to set up. It is the wrong trade for this stack:

- **Its value is discovery.** It watches the Docker API and configures virtual hosts
  for every container that asks. Here there is exactly one upstream, and it never moves.
- **It needs the Docker socket.** Both containers mount `/var/run/docker.sock`, and in
  the usual setup that includes the internet-facing proxy. The socket is root on the
  host, and `:ro` on the mount does not make the API read-only. A bug in the edge
  container becomes a host compromise.
- **The config should be a file you can read.** TLS settings, headers, WebSocket
  handling, timeouts and body size are reviewable in a diff and testable with
  `nginx -t`, instead of generated from container labels.

The cost is about 140 lines of commented shell in `nginx/start.sh` and `certbot/loop.sh`,
which solve the usual chicken-and-egg (nginx cannot serve HTTPS without a certificate;
certbot cannot get one without nginx answering the challenge) by starting on HTTP and
switching once the certificate appears. No dummy certificate, no one-off init script.
If you host many apps on one box and add them often, nginx-proxy or Traefik is the
better tool.

## Failure modes this stack is designed around

### 1. The certificate stops renewing, and nobody is told

Let's Encrypt stopped sending expiry reminder emails in 2025. Renewal can fail
silently for months of quiet reasons: DNS moved, someone closed port 80, a rate limit.
Worse, renewal can *succeed*: the new file is on disk, nginx never reloaded it, and
browsers see the old certificate expire while every file looks fine.

- certbot retries every 30 minutes after a failure, not just at the next daily run;
- nginx reloads whenever the certificate file changes, and only if `nginx -t` accepts it;
- `healthcheck.sh` reads the certificate **served on port 443**, not the file, and
  alerts below 14 days. Renewal normally happens around 30 days before expiry, so an
  alert means two weeks of runway for a human, not an outage.

### 2. Backups that were never restored

A backup job that runs every night proves nothing. The usual surprises: a truncated
dump that nobody opened, a database restored without the encryption key, a restore
procedure that exists only in someone's memory.

- every dump is converted back to SQL in full and discarded (`pg_restore -f /dev/null`)
  before it is accepted; `pg_restore --list` would only read the table of contents;
- the data archive is checked with `gzip -t` and `tar -t`, both files are checksummed,
  and nothing without the `.partial` suffix has failed verification;
- old backups are deleted only after a new one is complete, so a broken job cannot
  rotate away the last good copies;
- the health check alerts when the newest *complete* backup set is older than 26
  hours: the cron job itself can die, and a dead cron job sends no failure alert;
- `restore.sh` makes restoring a single command, and the drill below makes it a habit.

### 3. The disk fills up

On a 40 GB VPS the usual suspects are Docker's container logs (the default driver
never rotates), n8n's execution history, local backups, old kernels in `/boot`, and
the monitoring's own logs. When the disk is full, PostgreSQL stops accepting writes
and n8n goes down with it.

- every container log is capped at 3 x 10 MB;
- n8n prunes executions older than 14 days or beyond 10,000;
- backups are rotated, unattended-upgrades removes unused kernels, `logrotate.example`
  covers the cron logs;
- the backup refuses to start below `BACKUP_MIN_FREE_MB` instead of filling the disk
  halfway through;
- the health check alerts at 85% of space **or inodes** (millions of small files can
  exhaust inodes on a disk that looks half empty).

### 4. Alert spam

A check that fires every five minutes is muted within a day, and a muted channel is
the same as no monitoring.

- a check must fail two runs in a row (10 minutes) before it alerts: a container
  restarting during an upgrade is not an incident;
- it alerts once per transition, sends one `RECOVERED` message, and repeats only once
  a day while it stays broken (`HEALTH_RENOTIFY_HOURS`, 0 to disable);
- everything that changed in one run goes out as a single message;
- if Telegram is unreachable, the state is not saved, so the alert is retried rather
  than lost;
- `--test-alert` exists because an alert path that has never fired has not been tested.

### Smaller ones, handled in passing

- **n8n is recreated with a new IP after an upgrade**, and nginx keeps proxying to the
  old one. nginx resolves the container per request through Docker's DNS.
- **Docker bypasses ufw.** A published port is public whatever ufw says. Only nginx
  publishes ports; the drill override binds to `127.0.0.1`.
- **`docker compose stop` kills running executions** after Docker's default 10 seconds.
  n8n gets 45.
- **`latest` jumps major versions.** n8n 3 nightlies are already published. The full
  n8n version is pinned in `.env`; PostgreSQL's major version is pinned in the
  compose file, because a major upgrade is a dump and restore, not a tag change.
- **Hardening locks you out.** The SSH step refuses to run without an authorized key,
  validates with `sshd -t`, reverts on failure, and prints the effective settings.
- **The monitor dies with the machine.** `healthcheck.sh` cannot report that the whole
  VPS is gone. Add a free external uptime check on `/healthz/readiness`.

## Restore drill

A backup you have never restored is a hypothesis. Once a quarter, on a scratch VM,
never on production:

1. Fresh Ubuntu VM with Docker. Clone this repository.
2. Copy `.env` from your password manager (same `N8N_ENCRYPTION_KEY` and `POSTGRES_*`)
   and one backup set (the `.dump`, `.tar.gz` and `.sha256` of one stamp) into
   `BACKUP_DIR`.
3. Start PostgreSQL and n8n with the drill override. It cuts n8n off from the
   internet: a restored n8n comes back with its workflows **active**, and on a machine
   with internet access its schedules would send yesterday's emails again.

   ```bash
   export COMPOSE_FILES="docker-compose.yml docker-compose.drill.yml"
   sudo docker compose -f docker-compose.yml -f docker-compose.drill.yml up -d postgres n8n drill-proxy
   sudo COMPOSE_FILES="$COMPOSE_FILES" ./scripts/restore.sh --list
   sudo COMPOSE_FILES="$COMPOSE_FILES" ./scripts/restore.sh <STAMP> --skip-safety-backup
   ```

4. From your machine: `ssh -L 5678:127.0.0.1:5678 you@drill-vm`, open
   `http://localhost:5678`, and log in with your production account.
5. Open one credential: if its fields display, the encryption key matches. Open a
   few workflows and the latest executions.
6. Write down the date, the stamp and how long it took. That number is your real
   recovery time; the one in your head is optimistic.

Destroy the VM afterwards: it holds a copy of production data.

## Upgrading

- **n8n:** back up, read the release notes between your version and the target,
  change `N8N_VERSION` in `.env`, then `docker compose pull n8n && docker compose up -d n8n`.
  Database migrations run on start and are one-way; the backup is your way back.
- **PostgreSQL major version:** `backup.sh`, stop the stack, change the image tag and
  give the service a new volume, start PostgreSQL alone, `restore.sh <stamp> --db-only`.
  The official image for PostgreSQL 18 also moved its data directory, so read its notes
  before going there.
- **Everything else:** `docker compose pull && docker compose up -d` picks up patch
  releases of nginx 1.30, PostgreSQL 17 and Alpine.

## What was verified

Locally, on the files in this repository:

- `bash -n` on every script; ShellCheck 0.11 with no findings at any severity
  (`nginx/start.sh` and `certbot/loop.sh` checked as POSIX `sh`, since they run on
  Alpine's BusyBox shell).
- Both compose files parse as YAML and validate against the official Compose
  Specification JSON schema; a policy script checks that only nginx publishes ports,
  PostgreSQL is only on the internal network, every image is pinned, and every
  long-running service has a restart policy, log rotation and a memory limit.
- `nginx/start.sh` run against nginx 1.30.5 with real `nginx -t`: no certificate,
  certificate appears, certificate replaced by a corrupt one (previous config kept),
  restart with a corrupt certificate (falls back to HTTP). The rendered config was then
  served on loopback ports: 444 for unknown hosts, health endpoint, ACME path, redirect
  with path and query kept, TLS refused for unknown SNI and for TLS 1.1, security
  headers present.
- `backup.sh`, `healthcheck.sh` and the restore guard rails run against stubbed
  `docker`/`curl`/`openssl`: verification failures, rotation, low disk, alert threshold,
  recovery, daily reminder, Telegram outage and retry, and that the bot token never
  appears in a process's arguments.

Not verified here, and worth watching on the first real deployment: the containers
themselves (image entry points, healthchecks, the n8n readiness endpoint), certificate
issuance against Let's Encrypt, `docker compose run` streaming the volume tarball, a
real restore, and `harden-ubuntu.sh` on Ubuntu (run it with `--dry-run` first).

## En français

Un modèle prêt à déployer pour faire tourner n8n et PostgreSQL sur un seul VPS Ubuntu,
derrière Nginx avec certificats Let's Encrypt automatiques. Sauvegardes nocturnes
vérifiées (et copie hors site optionnelle), restauration en une commande, alertes
Telegram uniquement quand l'état change, et un script de durcissement du serveur
(pare-feu, fail2ban, mises à jour automatiques, SSH par clé seulement). C'est un modèle
à adapter, vérifié localement, pas un service géré.

MIT licensed.
