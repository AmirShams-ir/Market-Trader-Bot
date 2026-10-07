#!/usr/bin/env bash
# bootstrap-sbc.sh — lightweight optimizer for ARM SBCs running Debian/Ubuntu/Armbian.
# Optimized for 512 MB–2 GB RAM SBCs. Keeps the OS lean, uses ZRAM, enables BBR,
# protects low-RAM systems with earlyoom, and avoids unnecessary compiler/scientific stacks.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
LOG="/var/log/server-${SCRIPT_NAME%.sh}.log"
SYSCTL_FILE="/etc/sysctl.d/99-sbc-server.conf"
BBR_FILE="/etc/sysctl.d/99-sbc-bbr.conf"
JOURNAL_FILE="/etc/systemd/journald.conf.d/10-sbc-server.conf"

if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo --preserve-env=PATH bash "$0" "$@"; fi
    echo "Root privileges required."; exit 1
fi

[[ -r /etc/os-release ]] || { echo "Cannot detect OS."; exit 1; }
. /etc/os-release
if [[ "${ID}" != "debian" && "${ID}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
    echo "Debian/Ubuntu/Armbian only."; exit 1
fi

info(){ printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die(){ printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
has_systemd(){ [[ -d /run/systemd/system ]] && has_cmd systemctl; }

mkdir -p "$(dirname "$LOG")"
touch "$LOG"
exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)

info "============================================================"
info " SBC Lightweight Optimizer"
info " Host: $(hostname)"
info " OS: ${PRETTY_NAME:-unknown}"
info "============================================================"

RAM_MB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
CPU_THREADS="$(nproc)"
ROOT_AVAIL_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
info "RAM: ${RAM_MB} MB | CPU threads: ${CPU_THREADS} | Arch: ${ARCH} | Root free: ${ROOT_AVAIL_MB} MB"

export DEBIAN_FRONTEND=noninteractive
info "Installing SBC base/Python prerequisites..."
apt-get update
apt-get install -y ca-certificates curl wget git python3 python3-pip python3-venv libffi-dev libssl-dev zram-tools systemd-timesyncd
ok "SBC base packages installed"

if has_systemd; then
    timedatectl set-ntp true 2>/dev/null || warn "Could not enable NTP"
    systemctl enable --now systemd-timesyncd.service 2>/dev/null || true
    ok "Time synchronization configured"
fi

info "Configuring ZRAM..."
if (( RAM_MB <= 1024 )); then ZRAM_PERCENT=100
elif (( RAM_MB <= 2048 )); then ZRAM_PERCENT=75
elif (( RAM_MB <= 4096 )); then ZRAM_PERCENT=50
else ZRAM_PERCENT=25
fi

if [[ -f /etc/default/zramswap ]]; then
    cp -a /etc/default/zramswap "/etc/default/zramswap.bak.$(date +%Y%m%d-%H%M%S)"
fi
cat >/etc/default/zramswap <<EOF
# Managed by ${SCRIPT_NAME}
ALGO=zstd
PERCENT=${ZRAM_PERCENT}
PRIORITY=100
EOF

if has_systemd; then
    systemctl daemon-reload
    if systemctl list-unit-files 2>/dev/null | grep -q '^zramswap.service'; then
        systemctl enable --now zramswap.service || warn "Could not start zramswap.service"
        if swapon --show --noheadings 2>/dev/null | grep -q zram; then
            ok "ZRAM active at ${ZRAM_PERCENT}% profile"
        else
            warn "zramswap.service exists but no active zram swap was detected"
        fi
    else
        warn "zramswap.service is unavailable; ZRAM configuration was saved"
    fi
else
    warn "systemd unavailable; ZRAM activation skipped"
fi

info "Checking disk swap..."
if swapon --show --noheadings 2>/dev/null | grep -q .; then
    ok "Existing swap detected; leaving it unchanged"
else
    SWAP_SIZE="512M"
    (( RAM_MB <= 512 )) && SWAP_SIZE="768M"
    (( RAM_MB > 2048 )) && SWAP_SIZE="1G"
    if [[ ! -e /swapfile ]]; then
        if has_cmd fallocate && fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then :
        else
            case "$SWAP_SIZE" in
                512M) dd if=/dev/zero of=/swapfile bs=1M count=512 status=progress ;;
                768M) dd if=/dev/zero of=/swapfile bs=1M count=768 status=progress ;;
                1G) dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress ;;
            esac
        fi
        chmod 600 /swapfile
    fi
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw,pri=10 0 0' >>/etc/fstab
    ok "Emergency disk swap enabled: ${SWAP_SIZE}"
fi

info "Applying conservative SBC kernel/network tuning..."
cat >"$SYSCTL_FILE" <<EOF
# Managed by ${SCRIPT_NAME}
vm.swappiness=100
vm.vfs_cache_pressure=100
fs.file-max=65536
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
EOF
sysctl --system >/dev/null
ok "SBC kernel/network baseline applied"

info "Checking TCP BBR..."
modprobe tcp_bbr 2>/dev/null || true
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    cat >"$BBR_FILE" <<'EOF'
# Managed by SBC lightweight optimizer
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null
    ok "TCP BBR enabled"
else
    warn "BBR is not available in the current kernel"
fi

if has_systemd; then
    info "Limiting system journal..."
    mkdir -p /etc/systemd/journald.conf.d
    cat >"$JOURNAL_FILE" <<'EOF'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=25M
MaxRetentionSec=7day
Compress=yes
EOF
    systemctl restart systemd-journald
    ok "Journald limits applied"
fi

if (( RAM_MB <= 2048 )); then
    info "Installing earlyoom for low-RAM protection..."
    apt-get install -y earlyoom
    if has_systemd; then systemctl enable --now earlyoom.service || warn "Could not enable earlyoom"; fi
    ok "earlyoom enabled for low-RAM system"
else
    info "RAM > 2 GB; skipping earlyoom"
fi

info "CPU governor left at kernel default (power/thermal safe)"

if has_systemd; then
    for svc in bluetooth.service cups.service ModemManager.service; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
            systemctl disable --now "$svc" 2>/dev/null || true
            info "Disabled optional service: ${svc}"
        fi
    done
fi

info "Cleaning package cache..."
apt-get autoremove -y
apt-get autoclean -y

echo
info "============================================================"
ok "SBC optimization completed"
info "RAM:       ${RAM_MB} MB"
info "CPU:       ${CPU_THREADS} threads"
info "Arch:      ${ARCH}"
info "ZRAM:      ${ZRAM_PERCENT}% profile"
info "Swap:"
swapon --show 2>/dev/null || true
info "BBR:"
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
info "Swappiness:"
sysctl vm.swappiness 2>/dev/null || true
info "Memory:"
free -h
info "Log: ${LOG}"
info "============================================================"

unset RAM_MB CPU_THREADS ROOT_AVAIL_MB ARCH ZRAM_PERCENT SWAP_SIZE
