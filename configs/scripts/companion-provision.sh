#!/usr/bin/env bash
# companion-provision.sh — UACOM Raspberry Pi 5 base provisioning (idempotent).
# Run as root on a fresh Ubuntu Server 24.04 arm64 / Raspberry Pi OS Bookworm 64-bit.
set -eu

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

UAV_USER="${UAV_USER:-uav}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "== UACOM provisioning =="

echo "-- base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential git curl wget ca-certificates gnupg \
  python3 python3-pip python3-venv \
  network-manager modemmanager iproute2 nftables iptables \
  wireguard-tools chrony jq socat tcpdump iperf3 mtr-tiny \
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
  v4l-utils ffmpeg vim htop

echo "-- users and groups"
id -u "$UAV_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$UAV_USER"
for g in dialout video render gpio plugdev; do
  getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$UAV_USER" || true
done
usermod -aG sudo "$UAV_USER" 2>/dev/null || true

echo "-- time sync"
systemctl enable --now chrony 2>/dev/null || true

echo "-- disable unneeded services"
for svc in cups cups-browsed avahi-daemon bluetooth rpcbind; do
  systemctl disable --now "$svc" 2>/dev/null || true
done

echo "-- SSH hardening"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-uacom.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 30
ClientAliveCountMax 3
EOF
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

echo "-- firewall"
install -D -m 0644 "$REPO_ROOT/configs/nftables/uacom.nft" /etc/nftables/uacom.nft
nft -f /etc/nftables/uacom.nft || true
systemctl enable nftables 2>/dev/null || true

echo "-- udev rules"
install -D -m 0644 "$REPO_ROOT/configs/udev/99-flight-controller.rules" \
  /etc/udev/rules.d/99-flight-controller.rules
udevadm control --reload && udevadm trigger

echo "-- log dir"
install -d -o "$UAV_USER" -g "$UAV_USER" -m 0755 /var/log/uacom

echo "-- disable serial console on ttyAMA0 (free UART for FC)"
if [ -f /boot/firmware/cmdline.txt ]; then
  sed -i 's/ console=serial0,[0-9]*//g; s/ console=ttyAMA0,[0-9]*//g' /boot/firmware/cmdline.txt
fi
systemctl disable --now serial-getty@ttyAMA0.service 2>/dev/null || true

echo "== base provisioning complete. Run install-stack.sh next. =="
