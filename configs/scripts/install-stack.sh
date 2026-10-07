#!/usr/bin/env bash
# install-stack.sh — UACOM C2 stack install (mavlink-router + services + scripts).
set -eu

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "== installing UACOM C2 stack =="

echo "-- build & install mavlink-router"
if ! command -v mavlink-routerd >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends meson ninja-build pkg-config g++ git
  tmp="$(mktemp -d)"
  git clone --depth 1 https://github.com/mavlink-router/mavlink-router.git "$tmp/mr"
  cd "$tmp/mr"
  git submodule update --init --recursive
  meson setup build .
  ninja -C build
  ninja -C build install
  ldconfig
  cd /
  rm -rf "$tmp"
fi

echo "-- install configs"
install -D -m 0644 "$REPO_ROOT/configs/mavlink-router/main.conf" /etc/mavlink-router/main.conf
mkdir -p /etc/wireguard

echo "-- install scripts"
install -D -m 0755 "$REPO_ROOT/configs/scripts/wan-failover.sh"     /usr/local/sbin/wan-failover.sh
install -D -m 0755 "$REPO_ROOT/configs/scripts/video-tx.sh"         /usr/local/sbin/video-tx.sh
install -D -m 0755 "$REPO_ROOT/configs/scripts/companion-health.sh" /usr/local/sbin/companion-health.sh
install -D -m 0755 "$REPO_ROOT/configs/scripts/qos-apply.sh"        /usr/local/sbin/qos-apply.sh

echo "-- install systemd units"
for u in mavlink-router wan-failover video-tx companion-health; do
  install -D -m 0644 "$REPO_ROOT/configs/systemd/$u.service" "/etc/systemd/system/$u.service"
done
systemctl daemon-reload

echo "-- enable core services"
systemctl enable mavlink-router wan-failover companion-health video-tx

echo "-- policy routing tables"
grep -q '^100  wifi'     /etc/iproute2/rt_tables || echo '100  wifi'     >> /etc/iproute2/rt_tables
grep -q '^200  lte'      /etc/iproute2/rt_tables || echo '200  lte'      >> /etc/iproute2/rt_tables
grep -q '^300  starlink' /etc/iproute2/rt_tables || echo '300  starlink' >> /etc/iproute2/rt_tables

echo "== done. Next: place /etc/wireguard/wg0.conf, then:"
echo "   sudo systemctl enable --now wg-quick@wg0"
echo "   sudo systemctl start mavlink-router wan-failover video-tx companion-health"
