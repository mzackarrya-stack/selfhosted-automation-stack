# Hardening checklist

What `scripts/harden-ubuntu.sh` does, why, how to check it, and how to undo it.
Then the part no script can do for you.

Run it with `--dry-run` first. It targets Ubuntu 22.04 and 24.04, needs root, and
asks before the three steps that can cut you off: enabling the firewall, switching
SSH to key-only, and creating swap.

```bash
sudo ./scripts/harden-ubuntu.sh --dry-run
sudo ./scripts/harden-ubuntu.sh
```

---

## Before you run it

- [ ] **You log in with an SSH key, not a password.** From your own machine:
      `ssh-copy-id you@server`, then log in again and confirm no password was asked.
- [ ] **That user can use sudo**, and you know its password (or it has `NOPASSWD`).
      Disabling root login is only safe when another way to become root exists.
- [ ] **You have the provider's web console** (VNC/serial) open in a browser tab.
      If SSH breaks, that is the way back in.

## 1. Packages

`ufw`, `fail2ban`, `python3-systemd` (so fail2ban can read the journal) and
`unattended-upgrades`. Installed only if missing.

## 2. Firewall: ufw

- [ ] SSH allowed with `ufw limit` (port read from `sshd -T`, so a non-default port
      is respected). `limit` blocks an address after 6 connection attempts in 30 s.
- [ ] 80/tcp and 443/tcp allowed. Port 80 must stay open: Let's Encrypt validates
      over it, and it redirects to HTTPS.
- [ ] Everything else inbound denied, outbound allowed.

The allow rules are added **before** the default-deny policy, so re-running on a
live firewall never opens a gap where SSH is refused.

**Docker bypasses ufw.** Docker writes its own iptables rules for published ports,
in a chain ufw never sees. `ports: "5678:5678"` on n8n would put the editor on the
internet with ufw still reporting it closed. That is why only nginx publishes ports
in `docker-compose.yml`, and why the restore-drill override binds to `127.0.0.1`.
If you add a service, keep it unpublished or bind it to localhost.

Check: `ufw status verbose`. Undo: `ufw disable`.

## 3. fail2ban for sshd

`/etc/fail2ban/jail.d/sshd-hardening.local`: 5 failures in 10 minutes bans the
address for 1 hour; each repeat ban lasts longer, up to a week. `backend = systemd`
reads sshd's messages from the journal, which always exists, whereas
`/var/log/auth.log` only exists if rsyslog is installed (minimal images drop it).
A jail watching a file that is never written bans nobody and still looks healthy.

With password login disabled, brute force cannot succeed anyway. fail2ban keeps
the noise out of the logs and slows down scanners probing for the next weakness.

Check: `fail2ban-client status sshd`. Unban yourself:
`fail2ban-client set sshd unbanip <ip>`.

## 4. Automatic security updates

- [ ] `20auto-upgrades`: refresh package lists and apply upgrades daily.
- [ ] `52unattended-upgrades-local`: remove unused kernels and dependencies, so
      `/boot` does not fill up after a year of kernel updates.
- [ ] No automatic reboot. Some updates (kernel, libc) only apply after one;
      `/var/run/reboot-required` exists when that is the case. Reboot at a time you
      choose, and the containers come back by themselves (`restart: unless-stopped`).

Ubuntu's default policy applies security updates only. Docker itself, installed
from Docker's apt repository, is **not** upgraded automatically: upgrade it
deliberately.

Check: `systemctl status unattended-upgrades`, `/var/log/unattended-upgrades/`.

## 5. SSH: key-only

The script writes `/etc/ssh/sshd_config.d/00-hardening.conf`:

```
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin no            # or prohibit-password, see below
X11Forwarding no
```

**It refuses to do this unless it finds an authorized key** for root or for a
member of the `sudo`/`admin` group, in whatever `AuthorizedKeysFile` sshd is
actually configured with. No key, no change: the alternative is a server nobody
can log in to.

- A sudo user has a key: `PermitRootLogin no`.
- Only root has a key: `PermitRootLogin prohibit-password` (root keeps key login).
  Create a sudo user with a key and re-run to close root entirely.

**Why `00-`:** sshd keeps the *first* value it reads for an option, and Ubuntu
includes `sshd_config.d/*.conf` at the very top of `sshd_config`. Cloud images
often ship `50-cloud-init.conf` with `PasswordAuthentication yes`; editing the main
`sshd_config` loses to it silently. `00-` is read first and wins.

The new config goes through `sshd -t` before any reload; if the test fails, the
file is reverted. Afterwards the script prints the *effective* values from
`sshd -T`, which is the only reliable way to know what sshd will do.

- [ ] **Keep the current session open and test a new login in a second terminal.**
      Existing sessions survive a reload; that is your safety net.

Check: `sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '`.
Undo: delete the file, `systemctl reload ssh`.

## 6. Swap

A 2 GB `/swapfile` if the machine has **no swap at all** (common on VPS images),
plus `vm.swappiness = 10`. Without swap, one memory spike (a big workflow, a
`pg_dump` at 3 a.m.) gets a process killed by the OOM killer, and the process the
kernel picks is not always the one that caused it. With low swappiness, swap is a
cushion for spikes, not working memory. The container memory limits in
`docker-compose.yml` are the other half: they cap what one service can take.

Skipped when swap exists, when `/swapfile` exists but is inactive (left for you to
look at), or when the disk lacks space for it plus 1 GB.

Check: `swapon --show`, `free -h`.

---

## Not automated: do these by hand

- [ ] **A non-root sudo user with an SSH key**, and root login disabled (step 5).
- [ ] **Provider firewall** (if your host has one) mirroring ufw: 22, 80, 443. Two
      layers, and the outer one also stops traffic before it reaches the VM.
- [ ] **2FA on the hosting account and the DNS registrar.** Whoever controls DNS
      can get a valid certificate for your domain.
- [ ] **`.env` is `chmod 600`, owned by root**, and `N8N_ENCRYPTION_KEY` is stored in
      a password manager, outside this server.
- [ ] **Off-site backups encrypted** (an rclone `crypt` remote), with credentials
      that can write but ideally not delete (object lock / versioning on the bucket),
      so an attacker on the box cannot erase the backups too.
- [ ] **The `docker` group is root.** Anyone in it can mount `/` into a container.
      Add nobody to it you would not give root.
- [ ] **Two-factor authentication on the n8n owner account** (your n8n user
      settings). The editor runs arbitrary code by design; its login is the real
      front door.
- [ ] **An external uptime check** (any free HTTP monitor) on
      `https://<host>/healthz/readiness`. `healthcheck.sh` runs on the server itself
      and cannot report that the whole server is gone.
- [ ] **A restore drill**, on a calendar. See the README.

Changing the SSH port is optional. It cuts log noise, not risk; with key-only login
and fail2ban there is little left for it to do. If you change it, change it in
`sshd_config` first, re-run this script so ufw and fail2ban follow, and test before
closing your session.
