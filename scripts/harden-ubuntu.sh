#!/usr/bin/env bash
# harden-ubuntu.sh - baseline hardening for the Ubuntu VPS that runs this stack.
#
#   1. packages      ufw, fail2ban, unattended-upgrades
#   2. firewall      deny inbound except SSH (rate-limited), 80, 443        [asks]
#   3. fail2ban      sshd jail, journald backend, longer bans for repeat offenders
#   4. updates       unattended security upgrades, old kernels cleaned up
#   5. ssh           no passwords, no root password login, ONLY if a key exists  [asks]
#   6. swap          2 GB swap file if the machine has no swap at all       [asks]
#
# Idempotent: re-running changes nothing that is already in place, and says so.
# Every command is printed before it runs. See docs/HARDENING.md for the why.
#
# Usage: sudo ./scripts/harden-ubuntu.sh [--dry-run] [--yes] [--swap-size 2G]
#   --dry-run    show what would change, change nothing
#   --yes        answer yes to the prompts (the SSH key check still applies)
set -euo pipefail

DRY_RUN=0 ASSUME_YES=0 SWAP_SIZE=2G
while (($#)); do
    case $1 in
        -n | --dry-run) DRY_RUN=1 ;;
        -y | --yes) ASSUME_YES=1 ;;
        --swap-size) SWAP_SIZE=${2:?--swap-size needs a value like 2G}; shift ;;
        -h | --help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
    printf '    $ %s\n' "$*"
    if ((DRY_RUN)); then return 0; fi
    "$@"
}

confirm() {
    local reply
    if ((ASSUME_YES)); then
        info "$1 -> yes (--yes)"
        return 0
    fi
    if ((DRY_RUN)); then
        info "$1 -> would ask (dry run)"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "no terminal to ask '$1'; skipped (use --yes to accept)"
        return 1
    fi
    read -r -p "    $1 [y/N] " reply
    [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]
}

# write_file PATH MODE < content. Writes only when the content differs and sets
# FILE_CHANGED=1/0, so callers restart a service only when something changed.
FILE_CHANGED=0
write_file() {
    local path=$1 mode=$2 tmp
    tmp=$(mktemp)
    cat >"$tmp"
    if [[ -f $path ]] && cmp -s "$tmp" "$path"; then
        info "unchanged: $path"
        FILE_CHANGED=0
    elif ((DRY_RUN)); then
        info "would write: $path"
        diff -u "$path" "$tmp" 2>/dev/null | sed 's/^/      /' || sed 's/^/      + /' "$tmp"
        FILE_CHANGED=1
    else
        install -D -m "$mode" -o root -g root "$tmp" "$path"
        info "wrote: $path"
        FILE_CHANGED=1
    fi
    rm -f "$tmp"
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# ------------------------------------------------------------------ preflight
((EUID == 0)) || die "run as root: sudo $0"
[[ -r /etc/os-release ]] || die "/etc/os-release not found; this script targets Ubuntu"
# shellcheck disable=SC1091
. /etc/os-release
if [[ ${ID:-} != ubuntu ]]; then
    warn "this is ${PRETTY_NAME:-an unknown OS}, not Ubuntu"
    confirm "Continue anyway?" || exit 1
fi
MODE=""
if ((DRY_RUN)); then MODE=" (DRY RUN: nothing will change)"; fi
info "system: ${PRETTY_NAME:-unknown}${MODE}"

SSH_PORTS=22
if command -v sshd >/dev/null 2>&1; then
    # `sshd -T` and `sshd -t` need the privilege-separation directory, which Ubuntu
    # only creates while ssh.service runs (not always the case with socket activation).
    if ((!DRY_RUN)) && [[ ! -d /run/sshd ]]; then
        mkdir -m 0755 /run/sshd
    fi
    detected=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | paste -sd, -) || true
    SSH_PORTS=${detected:-22}
fi
info "SSH port(s) detected: ${SSH_PORTS}"

# ------------------------------------------------------------------ 1. packages
say "1/6 packages"
missing=()
for p in ufw fail2ban python3-systemd unattended-upgrades; do
    pkg_installed "$p" || missing+=("$p")
done
if ((${#missing[@]})); then
    run apt-get update -q
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"
else
    info "already installed: ufw fail2ban python3-systemd unattended-upgrades"
fi

# ------------------------------------------------------------------ 2. firewall
say "2/6 firewall (ufw): allow SSH ${SSH_PORTS} (rate-limited), 80, 443; deny the rest"
if ! command -v ufw >/dev/null 2>&1 && ((DRY_RUN)); then
    info "ufw is not installed yet (dry run); it would be configured as below"
fi
# Allow rules first, defaults second: on an already-active firewall this order never
# leaves a window where SSH is denied.
IFS=, read -r -a ports <<<"$SSH_PORTS"
for port in "${ports[@]}"; do
    run ufw limit "${port}/tcp" comment 'SSH, rate-limited'
done
run ufw allow 80/tcp comment 'HTTP: ACME challenges + redirect'
run ufw allow 443/tcp comment 'HTTPS'
run ufw default deny incoming
run ufw default allow outgoing
if ((!DRY_RUN)) && [[ $(ufw status) == "Status: active"* ]]; then
    info "ufw already active; rules above are in effect"
elif confirm "Enable ufw now? SSH on port(s) ${SSH_PORTS} stays open."; then
    run ufw --force enable
else
    warn "ufw left disabled"
fi
info "Reminder: ports published by Docker bypass ufw. Only nginx publishes ports in this stack."

# ------------------------------------------------------------------ 3. fail2ban
say "3/6 fail2ban: sshd jail"
write_file /etc/fail2ban/jail.d/sshd-hardening.local 0644 <<EOF
# Managed by scripts/harden-ubuntu.sh (selfhosted-automation-stack).
# .local files are read after the distribution's .conf files, so these values win.
[sshd]
enabled  = true
port     = ${SSH_PORTS}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
# Each repeat ban lasts longer, capped at one week.
bantime.increment = true
bantime.maxtime   = 1w
EOF
fail2ban_changed=$FILE_CHANGED
run systemctl enable --now fail2ban
if ((fail2ban_changed)); then
    run systemctl restart fail2ban
fi
if ((!DRY_RUN)); then
    sleep 2
    if fail2ban-client status sshd >/dev/null 2>&1; then
        info "sshd jail is active"
    else
        warn "sshd jail not reported active; check: fail2ban-client status sshd"
    fi
fi

# ------------------------------------------------------------------ 4. automatic security updates
say "4/6 unattended-upgrades: security updates daily, unused kernels removed"
write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
// Managed by scripts/harden-ubuntu.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
write_file /etc/apt/apt.conf.d/52unattended-upgrades-local 0644 <<'EOF'
// Managed by scripts/harden-ubuntu.sh
// Old kernels are the classic way /boot fills up on a small VPS.
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Never reboot on its own: a reboot is your decision. Check /var/run/reboot-required.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
run systemctl enable --now unattended-upgrades

# ------------------------------------------------------------------ 5. ssh
say "5/6 SSH: key-only login"

# key_count FILE -> number of usable public keys in an authorized_keys file
key_count() {
    [[ -f $1 ]] || { echo 0; return; }
    grep -vE '^[[:space:]]*(#|$)' "$1" |
        grep -cE '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+AAAA[A-Za-z0-9+/=]+' ||
        true
}

# user_has_key USER -> 0 if one of sshd's AuthorizedKeysFile paths holds a key for USER
user_has_key() {
    local user=$1 home pattern path n
    home=$(getent passwd "$user" | cut -d: -f6) || true
    [[ -n $home ]] || return 1
    for pattern in $AUTH_KEYS_FILES; do
        path=${pattern//%h/$home}
        path=${path//%u/$user}
        path=${path//%%/%}
        [[ $path == /* ]] || path="$home/$path"
        n=$(key_count "$path")
        if ((n > 0)); then
            info "found ${n} key(s) for ${user} in ${path}"
            return 0
        fi
    done
    return 1
}

if ! command -v sshd >/dev/null 2>&1; then
    info "OpenSSH server not installed; nothing to do"
else
    AUTH_KEYS_FILES=$(sshd -T 2>/dev/null | awk '$1 == "authorizedkeysfile" { $1 = ""; print }') || true
    AUTH_KEYS_FILES=${AUTH_KEYS_FILES:-.ssh/authorized_keys .ssh/authorized_keys2}

    root_key=0
    if user_has_key root; then root_key=1; fi
    # Members of the sudo/admin groups (Ubuntu's default sudoers grants both).
    mapfile -t sudo_members < <(getent group sudo admin 2>/dev/null | cut -d: -f4 | tr ',' '\n' | sed '/^$/d' | sort -u)
    sudo_key_users=()
    for u in "${sudo_members[@]}"; do
        [[ $u == root ]] && continue
        if user_has_key "$u"; then sudo_key_users+=("$u"); fi
    done

    if ((root_key == 0 && ${#sudo_key_users[@]} == 0)); then
        warn "no authorized SSH key found for root or for any sudo user."
        warn "Refusing to disable password login: you would lock yourself out."
        info "From your own machine: ssh-copy-id <user>@<server>, log in with the key, then re-run."
    else
        if ((${#sudo_key_users[@]})); then
            permit_root=no
            info "sudo user(s) with a key: ${sudo_key_users[*]} -> root login disabled entirely"
            info "from now on log in as ${sudo_key_users[0]} (or another of them) and use sudo;"
            info "make sure that user can actually sudo (knows its password, or NOPASSWD)"
        else
            permit_root=prohibit-password
            info "only root has a key -> root keeps key login, passwords are disabled"
            info "better: create a sudo user with a key, then re-run to disable root login"
        fi
        if confirm "Apply key-only SSH (PasswordAuthentication no, PermitRootLogin ${permit_root})?"; then
            dropin=/etc/ssh/sshd_config.d/00-hardening.conf
            previous=""
            [[ -f $dropin ]] && previous=$(cat "$dropin")
            # 00- because sshd keeps the FIRST value it reads: this file must sort before
            # cloud-init's 50-cloud-init.conf, which often sets PasswordAuthentication yes.
            write_file "$dropin" 0644 <<EOF
# Managed by scripts/harden-ubuntu.sh (selfhosted-automation-stack).
# sshd uses the first value it reads for each option; 00- sorts before 50-cloud-init.conf.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin ${permit_root}
X11Forwarding no
EOF
            if ((FILE_CHANGED && !DRY_RUN)); then
                if ! sshd -t; then
                    if [[ -n $previous ]]; then
                        printf '%s\n' "$previous" >"$dropin"
                    else
                        rm -f "$dropin"
                    fi
                    die "sshd -t rejected the new config; it has been reverted, nothing reloaded"
                fi
                if systemctl is-active --quiet ssh.service; then
                    run systemctl reload ssh.service
                elif systemctl is-active --quiet sshd.service; then
                    run systemctl reload sshd.service
                else
                    info "ssh.service not running (socket activation): applies to the next connection"
                fi
            fi
            if ((!DRY_RUN)); then
                effective=$(sshd -T 2>/dev/null | awk '$1 == "passwordauthentication" || $1 == "permitrootlogin" { printf "%s=%s ", $1, $2 }') || true
                info "effective: ${effective}"
                if [[ $effective != *"passwordauthentication=no"* ]]; then
                    warn "another sshd config still enables passwords; check: grep -ri passwordauthentication /etc/ssh/"
                fi
            fi
            echo
            info ">>> KEEP THIS SESSION OPEN. In a second terminal, check that a new SSH login works."
        else
            info "SSH left unchanged"
        fi
    fi
fi

# ------------------------------------------------------------------ 6. swap
say "6/6 swap"
if [[ -n $(swapon --show=NAME --noheadings 2>/dev/null) ]]; then
    info "swap already active: $(swapon --show=NAME,SIZE --noheadings | tr -s ' ' | paste -sd, -)"
elif [[ -e /swapfile ]]; then
    warn "/swapfile exists but is not active; not touching it (swapon /swapfile, or remove it and re-run)"
else
    swap_bytes=$(numfmt --from=iec "$SWAP_SIZE") || die "--swap-size: cannot parse '$SWAP_SIZE'"
    swap_mb=$((swap_bytes / 1024 / 1024))
    free_mb=$(df -m --output=avail / | awk 'NR == 2 { print $1 }')
    if ((free_mb < swap_mb + 1024)); then
        warn "only ${free_mb} MB free on /; not creating a ${swap_mb} MB swap file"
    elif confirm "No swap configured. Create a ${SWAP_SIZE} swap file at /swapfile?"; then
        make_swap() {
            if [[ ${1:-} == dd ]]; then
                run dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none
            else
                run fallocate -l "$swap_bytes" /swapfile ||
                    run dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none
            fi
            run chmod 600 /swapfile
            run mkswap /swapfile
        }
        make_swap
        if ! run swapon /swapfile; then
            warn "swapon refused the file (some filesystems reject fallocate'd swap); rebuilding with dd"
            run rm -f /swapfile
            make_swap dd
            run swapon /swapfile
        fi
        if grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
            info "/etc/fstab already has /swapfile"
        elif ((DRY_RUN)); then
            info "would append to /etc/fstab: /swapfile none swap sw 0 0"
        else
            echo '/swapfile none swap sw 0 0' >>/etc/fstab
            info "added /swapfile to /etc/fstab"
        fi
    else
        info "no swap created"
    fi
fi
# Swap as a cushion against the OOM killer, not as working memory.
write_file /etc/sysctl.d/99-swappiness.conf 0644 <<'EOF'
# Managed by scripts/harden-ubuntu.sh: use swap only under real memory pressure.
vm.swappiness = 10
EOF
if ((FILE_CHANGED)); then
    run sysctl -q --load=/etc/sysctl.d/99-swappiness.conf
fi

# ------------------------------------------------------------------ summary
say "done${MODE}"
cat <<'EOF'
    Verify:
      ufw status verbose
      fail2ban-client status sshd
      systemctl status unattended-upgrades --no-pager
      sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
      swapon --show
    Then a NEW ssh session from your machine, before closing this one.
EOF
