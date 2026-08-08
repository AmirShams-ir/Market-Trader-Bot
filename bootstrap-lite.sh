#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Description: Lightweight optimizer for small Debian/Ubuntu servers running
#              Freqtrade or similar low-resource workloads.
# Author: Amir Shams
# License: See GitHub repository for license details.
#
# Design goals:
#   - Safe, conservative, idempotent
#   - Suitable for 1-4 GB RAM / 1-2 CPU systems
#   - Keep the base OS lean
#   - Prefer ZRAM over aggressive disk swapping
#   - Enable BBR when supported
#   - Avoid risky "gaming/server benchmark" sysctl tweaks
#   - Install only Freqtrade prerequisites; Freqtrade itself is installed
#     separately using its official setup.sh / venv workflow.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
LOG="/var/log/server-${SCRIPT_NAME%.sh}.log"
SYSCTL_FILE="/etc/sysctl.d/99-lite-server.conf"
JOURNAL_FILE="/etc/systemd/journald.conf.d/10-lite-server.conf"

# -----------------------------------------------------------------------------
# Root
# -----------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo --preserve-env=PATH bash "$0" "$@"
    fi
    echo "Root privileges required."
    exit 1
fi

# -----------------------------------------------------------------------------
# OS validation
# -----------------------------------------------------------------------------
if [[ ! -r /etc/os-release ]]; then
    echo "Cannot detect OS."
    exit 1
fi

. /etc/os-release

if [[ "${ID}" != "debian" && "${ID}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
    echo "Debian/Ubuntu only."
    exit 1
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
info() { printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }
has_systemd() {
    [[ -d /run/systemd/system ]] && has_cmd systemctl
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)

info "============================================================"
info " Lightweight Server Optimizer"
info " Host: $(hostname)"
info " OS: ${PRETTY_NAME:-unknown}"
info "============================================================"

# -----------------------------------------------------------------------------
# Hardware profile
# -----------------------------------------------------------------------------
RAM_MB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
CPU_THREADS="$(nproc)"
ROOT_AVAIL_MB="$(df -Pm / | awk 'NR==2 {print $4}')"

info "RAM: ${RAM_MB} MB | CPU threads: ${CPU_THREADS} | Root free: ${ROOT_AVAIL_MB} MB"

# -----------------------------------------------------------------------------
# Base packages
# -----------------------------------------------------------------------------
info "Installing lightweight base/Freqtrade prerequisites..."

export DEBIAN_FRONTEND=noninteractive
apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    git \
    build-essential \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    python3-pandas \
    libffi-dev \
    libssl-dev \
    zram-tools \
    systemd-timesyncd

ok "Base packages installed"

# -----------------------------------------------------------------------------
# Time synchronization
# Freqtrade requires an accurate clock.
# -----------------------------------------------------------------------------
if has_systemd; then
    timedatectl set-ntp true 2>/dev/null || warn "Could not enable NTP"
    systemctl enable --now systemd-timesyncd.service 2>/dev/null || true
    ok "Time synchronization configured"
fi

# -----------------------------------------------------------------------------
# ZRAM
# -----------------------------------------------------------------------------
info "Configuring ZRAM..."

# Conservative size based on RAM.
# zram-tools' PERCENT is relative to physical RAM.
if (( RAM_MB <= 1024 )); then
    ZRAM_PERCENT=100
elif (( RAM_MB <= 2048 )); then
    ZRAM_PERCENT=75
elif (( RAM_MB <= 4096 )); then
    ZRAM_PERCENT=50
else
    ZRAM_PERCENT=25
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

if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^zramswap.service'; then
    systemctl daemon-reload
    systemctl enable --now zramswap.service || warn "Could not start zramswap.service"
    ok "ZRAM configured at ${ZRAM_PERCENT}% of RAM"
else
    warn "zramswap.service not available; ZRAM configuration saved but not started"
fi

# -----------------------------------------------------------------------------
# Disk swap
# Keep a small emergency swap on disk. Do not recreate an existing swap.
# -----------------------------------------------------------------------------
info "Checking disk swap..."

if swapon --show --noheadings 2>/dev/null | grep -q .; then
    ok "Existing swap detected; leaving it unchanged"
else
    SWAP_SIZE="1G"
    (( RAM_MB <= 1024 )) && SWAP_SIZE="1G"
    (( RAM_MB > 8192 )) && SWAP_SIZE="512M"

    if [[ ! -e /swapfile ]]; then
        fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$(( ${SWAP_SIZE%G} * 1024 )) status=progress
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
    fi

    swapon /swapfile
    grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab ||
        echo '/swapfile none swap sw,pri=10 0 0' >>/etc/fstab

    ok "Emergency disk swap enabled: ${SWAP_SIZE}"
fi

# -----------------------------------------------------------------------------
# Sysctl
# Conservative settings. No unsafe high-throughput benchmark tuning.
# -----------------------------------------------------------------------------
info "Applying conservative kernel/network tuning..."

cat >"$SYSCTL_FILE" <<EOF
# Managed by ${SCRIPT_NAME}

# Memory pressure
vm.swappiness=80
vm.vfs_cache_pressure=50

# File descriptors
fs.file-max=100000

# TCP safety/performance
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5

# Do not accept/send ICMP redirects
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

# Reverse path filtering
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
EOF

sysctl --system >/dev/null
ok "Kernel/network baseline applied"

# -----------------------------------------------------------------------------
# BBR
# -----------------------------------------------------------------------------
info "Checking TCP BBR..."

modprobe tcp_bbr 2>/dev/null || true

if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    cat > /etc/sysctl.d/99-bbr-lite.conf <<'EOF'
# Managed by lite server optimizer
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null
    ok "TCP BBR enabled"
else
    warn "BBR is not available in the current kernel"
fi

# -----------------------------------------------------------------------------
# Journald
# -----------------------------------------------------------------------------
if has_systemd; then
    info "Limiting system journal..."

    mkdir -p /etc/systemd/journald.conf.d
    cat >"$JOURNAL_FILE" <<'EOF'
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
MaxRetentionSec=14day
Compress=yes
EOF

    systemctl restart systemd-journald
    ok "Journald limits applied"
fi

# -----------------------------------------------------------------------------
# OOM protection for very small systems
# -----------------------------------------------------------------------------
if (( RAM_MB <= 2048 )); then
    info "Installing earlyoom for low-RAM protection..."
    apt-get install -y earlyoom

    if has_systemd; then
        systemctl enable --now earlyoom.service || warn "Could not enable earlyoom"
    fi

    ok "earlyoom enabled for low-RAM system"
else
    info "RAM > 2 GB; skipping earlyoom"
fi

# -----------------------------------------------------------------------------
# CPU governor
# Do not force performance mode: it increases power/heat and can be worse
# on tiny fanless devices. Leave the kernel's default governor in control.
# -----------------------------------------------------------------------------
info "CPU governor left at kernel default (power/thermal safe)"

# -----------------------------------------------------------------------------
# Disable unnecessary services only when they are installed and clearly unused.
# We intentionally do NOT disable networking, SSH, unattended upgrades, etc.
# -----------------------------------------------------------------------------
if has_systemd; then
    for svc in \
        bluetooth.service \
        cups.service \
        ModemManager.service
    do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
            systemctl disable --now "$svc" 2>/dev/null || true
            info "Disabled optional service: ${svc}"
        fi
    done
fi

# -----------------------------------------------------------------------------
# Package cleanup
# -----------------------------------------------------------------------------
info "Cleaning package cache..."

apt-get autoremove -y
apt-get autoclean -y

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
info "============================================================"
ok "Lightweight optimization completed"
info "RAM:       ${RAM_MB} MB"
info "CPU:       ${CPU_THREADS} threads"
info "ZRAM:      ${ZRAM_PERCENT}%"
info "Swap:"
swapon --show 2>/dev/null || true
info "BBR:"
sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
info "Swappiness:"
sysctl vm.swappiness 2>/dev/null || true
info "Log: ${LOG}"
info "============================================================"

unset RAM_MB CPU_THREADS ROOT_AVAIL_MB ZRAM_PERCENT SWAP_SIZE
