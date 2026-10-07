# 03 — Raspberry Pi 5 Companion Computer Manual

Target: **Raspberry Pi 5 (4 GB / 8 GB / 16 GB), arm64**, running **Ubuntu Server 24.04
LTS (64-bit)**. (Raspberry Pi OS Bookworm 64-bit also works; paths and package names
noted where they differ.)

## 1. Bill of materials

| Item | Suggested | Notes |
|------|-----------|-------|
| Companion | Raspberry Pi 5, 8 GB | 16 GB if running ROS 2 + vision |
| Storage | NVMe SSD via PCIe HAT, ≥128 GB | SD only for boot; NVMe for logs/video |
| Power | 5 V / 5 A (25 W) regulated BEC | Pi 5 peak ~5 A; brownouts are fatal |
| 5 GHz radio | USB 5 GHz adapter or M.2/PCIe Wi-Fi/Eth | High-gain antenna; do not rely on PCB antenna |
| LTE | USB mini-PCIe enclosure + Quectel RM500Q/RM520N | With SIM, ModemManager |
| Starlink | Starlink terminal + Ethernet | Aircraft/maritime kit |
| Flight controller link | UART (GPIO14/15) or USB | `/dev/ttyAMA0` or `/dev/ttyACM0` |
| Camera | Pi Camera Module 3 / HDMI capture | `libcamera` or GStreamer |
| Cooling | Active cooler / heatsinks | Thermal throttling kills C2 |
| RTC battery | Pi 5 RTC coin cell | Time continuity when unpowered |
| Fan + sensor | PWM fan, `rpi-heatsink`/thermal | Managed by `companion-health` |

## 2. Power architecture

```
Flight battery ──► BEC 5 V/5 A ──► Pi 5 (GPIO 5V or USB-C) ──► peripherals
                                     │
                                     └─ logic-level-safe UART to FC
```

Rules:
- **Dedicated, low-noise BEC** for the Pi; do not share a noisy 5 V rail with servos.
- Add bulk capacitance close to the Pi 5V.
- Monitor input voltage; `companion-health` triggers graceful shutdown below 4.75 V.
- Ground the Pi and FC together (single-point) and keep UART wiring short.

## 3. Flashing & first boot

### 3.1 Flash
Use Raspberry Pi Imager:
- OS: **Ubuntu Server 24.04 LTS (64-bit)** or Raspberry Pi OS Bookworm 64-bit.
- Enable SSH, set user `uav`, set Wi-Fi/locale, hostname `uacom-air`.

### 3.2 First boot
```bash
ssh uav@uacom-air.local
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update -a            # RPi OS / Ubuntu with rpi-eeprom
sudo reboot
```

### 3.3 Boot from NVMe (recommended)
```bash
sudo rpi-eeprom-config --edit
# set: BOOT_ORDER=0xf416   (NVMe first, then USB, then SD)
sudo reboot
```
Clone SD → NVMe:
```bash
sudo apt install -y rpi-clone       # RPi OS; on Ubuntu use dd/ddrescue
```

Then **remove the SD card** so boot devices are unambiguous.

## 4. Base provisioning

Run the repository provisioner (idempotent):
[`configs/scripts/companion-provision.sh`](../configs/scripts/companion-provision.sh)

It performs:
1. Timezone/hostname, user groups (`dialout`, `video`, `render`, `gpio`).
2. `apt` base packages (below).
3. Disable unnecessary services (avahi optional, cups, bluetooth if unused).
4. SSH hardening (key-only, no root), `unattended-upgrades` for security only.
5. `chrony` time sync.
6. `nftables` firewall from [`configs/nftables/uacom.nft`](../configs/nftables/uacom.nft).
7. Installs [`configs/udev/99-flight-controller.rules`](../configs/udev/99-flight-controller.rules).

Base packages:
```
build-essential git curl wget ca-certificates
python3 python3-pip python3-venv
network-manager modemmanager iproute2 nftables iptables
wireguard-tools chrony jq socat tcpdump
gstreamer1.0-tools gstreamer1.0-plugins-{base,good,bad,ugly}
v4l-utils libcamera-apps ffmpeg
```

Install the C2 stack:
[`configs/scripts/install-stack.sh`](../configs/scripts/install-stack.sh)
builds/installs `mavlink-router`, sets up `wg-quick`, and installs systemd units.

## 5. Flight controller link (UART)

Enable UART on GPIO14/15 and free it from the console.

`/boot/firmware/config.txt` (Pi 5 / Bookworm layout):
```
enable_uart=1
dtoverlay=uart0
dtparam=uart0=on
# optional: high-speed UART clock
# dtoverlay=disable-bt        # only if you need ttyAMA0 for FC
```

`/boot/firmware/cmdline.txt` — **remove** `console=serial0,115200` (or
`console=ttyAMA0`), keep everything else on one line.

Then:
```bash
sudo systemctl disable --now serial-getty@ttyAMA0.service
sudo usermod -aG dialout uav
sudo reboot
```

Verify:
```bash
ls -l /dev/ttyAMA0 /dev/serial0
```

Stable names via udev:
[`configs/udev/99-flight-controller.rules`](../configs/udev/99-flight-controller.rules)
```
# Flight controller by USB vendor/product
SUBSYSTEM=="tty", ATTRS{idVendor}=="26ac", ATTRS{idProduct}=="0011", SYMLINK+="fc", MODE="0660", GROUP="dialout"
SUBSYSTEM=="tty", ATTRS{idVendor}=="2dae", ATTRS{idProduct}=="1012", SYMLINK+="fc", MODE="0660", GROUP="dialout"
# LTE modem
SUBSYSTEM=="tty", ATTRS{idVendor}=="2c7c", SYMLINK+="lte", MODE="0660", GROUP="dialout"
```
```bash
sudo udevadm control --reload && sudo udevadm trigger
ls -l /dev/fc   # symlink resolves to the FC UART
```

**MAVLink baud:** use `921600` (or `1500000`) between FC and Pi. Set the same on the
FC (`SERIALx_BAUD` for ArduPilot, `SER_TELx_BAUD` for PX4) and on `mavlink-router`.

## 6. Services (systemd)

| Unit | File | Purpose |
|------|------|---------|
| `mavlink-router.service` | [`configs/systemd/mavlink-router.service`](../configs/systemd/mavlink-router.service) | MAVLink routing |
| `wan-failover.service` | [`configs/systemd/wan-failover.service`](../configs/systemd/wan-failover.service) | Multi-WAN health/failover |
| `wg-quick@wg0.service` | distro | WireGuard overlay |
| `video-tx.service` | [`configs/systemd/video-tx.service`](../configs/systemd/video-tx.service) | Camera→GCS stream |
| `companion-health.service` | [`configs/systemd/companion-health.service`](../configs/systemd/companion-health.service) | Thermal/power/disk supervisor |
| `autonomy.service` | optional | ROS 2 / MAVSDK mission node |

Enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mavlink-router wan-failover video-tx companion-health
sudo systemctl enable --now wg-quick@wg0
```

## 7. MAVLink routing

Config: [`configs/mavlink-router/main.conf`](../configs/mavlink-router/main.conf).

```ini
[General]
TcpServerPort=5760
ReportStats=true
MavlinkDialect=auto

[UartEndpoint fc]
Device=/dev/fc
Baud=921600

[UdpEndpoint gcs]
Mode=Normal
Address=10.8.0.20
Port=14550

[UdpEndpoint local]
Mode=Normal
Address=127.0.0.1
Port=14550
```

Add a **TCP endpoint** for on-demand high-reliability sessions (e.g. Starlink):
```ini
[TcpEndpoint gcs_tcp]
Address=10.8.0.20
Port=5780
```
(Or expose `TcpServerPort` and let the GCS connect inward over `wg0`.)

Validate:
```bash
sudo systemctl status mavlink-router
journalctl -u mavlink-router -f
# from GCS:
mavlink-router-status || mavproxy.py --master=udpout:10.8.0.10:14550
```

## 8. Camera & video

### 8.1 libcamera → GStreamer → H.264 → UDP
`video-tx.service` runs [`configs/scripts/video-tx.sh`](../configs/scripts/video-tx.sh):

```bash
libcamera-vid -n -t 0 --inline --codec h264 --width 1280 --height 720 \
  --framerate 30 --bitrate "$BITRATE" -o - \
  | gst-launch-1.0 -e fdsrc ! \
      h264parse config-interval=1 ! \
      rtph264pay pt=96 ! \
      udpsink host=10.8.0.20 port=5600 sync=false
```

Adaptive: the script reads `/run/wan-failover/active-link` and sets `BITRATE`.

### 8.2 GCS side
```bash
gst-launch-1.0 -v udpsrc port=5600 \
  caps="application/x-rtp,media=video,encoding-name=H264,payload=96" ! \
  rtph264depay ! avdec_h264 ! autovideosink sync=false
```

## 9. Thermal & power management (`companion-health`)

Reference: [`configs/scripts/companion-health.sh`](../configs/scripts/companion-health.sh)
and unit [`configs/systemd/companion-health.service`](../configs/systemd/companion-health.service).

Behavior:
- Poll `vcgencmd measure_temp` (or `/sys/class/thermal`) every 5 s.
- **≥ 75 °C:** reduce video bitrate one step, log warning.
- **≥ 80 °C:** disable video, log critical.
- **≥ 85 °C:** warn GCS via MAVLink `STATUSTEXT`, prepare shutdown if sustained.
- Input voltage < 4.75 V → `STATUSTEXT` warning; < 4.65 V → graceful shutdown after 10 s.
- Disk > 85 % → rotate logs, stop non-essential recording.

```bash
# temperature
vcgencmd measure_temp
# throttling flags
vcgencmd get_throttled     # 0x0 = healthy
```

## 10. Logging & blackbox

- `journald` with `SystemMaxUse=2G`.
- MAVLink telemetry log (from `mavlink-router` mirror) to NVMe, rotated.
- Video snapshots on events (optional).
- Optional remote sync to the VPS over `wg0` when idle.

## 11. Updating & fleet images

- Maintain a golden image: provision → configure → `rpi-clone`/`dd` → shrink.
- Version pins for `mavlink-router`, kernel, and firmware.
- `unattended-upgrades` for security only; application updates via a controlled job.
- A/B or snapshot strategy if using an NVMe.

## 12. Companion acceptance test

```bash
# 1. FC link
ls -l /dev/fc
sudo systemctl is-active mavlink-router
# 2. Overlay
sudo wg show
ping -c3 10.8.0.20
# 3. WAN failover state
cat /run/wan-failover/state.json
# 4. MAVLink heartbeat visible from GCS (0x01)
# 5. Video at expected bitrate for active link
# 6. Thermal: vcgencmd get_throttled == 0x0 under load
```

Continue to **[04 — Flight Control Stack](04-flight-control-stack.md)**.
