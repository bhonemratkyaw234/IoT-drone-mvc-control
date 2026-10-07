# IoT-drone-mvc-control — UAV Communications & Autonomy Platform

> Project code name: **UACOM** (UAV Communications & Autonomy Platform).

Technical documentation, reference architecture, network routing configuration, and
Raspberry Pi 5 companion-computer manuals for operating **autonomous and teleoperated
drones without a traditional RC transmitter**, over:

| Link | Role | Typical use |
|------|------|-------------|
| **5 GHz Local Wi-Fi** | Primary high-bandwidth, low-latency | Bench, line-of-sight, local site ops |
| **4G LTE Cellular** | Primary wide-area, low bandwidth | BVLOS metro/regional, backup link |
| **Starlink Satellite** | Primary wide-area, high latency | Remote/rural BVLOS, long-endurance relay |

The aircraft is controlled end-to-end via **MAVLink** command links (teleoperation) and
**mission / offboard** interfaces (autonomy). There is no 2.4 GHz RC link and no RC
transmitter in the safety path — link-loss and geofence failsafes are handled by the
flight controller and the companion computer.

---

## Document map

| # | Document | Contents |
|---|----------|----------|
| 00 | [Overview & Concepts](docs/00-overview.md) | Technology stack, link budget concepts, glossary, safety philosophy |
| 01 | [System Architecture](docs/01-system-architecture.md) | Hardware/software architecture, data flows, redundancy, block diagrams |
| 02 | [Network & Routing](docs/02-network-routing.md) | 5 GHz / LTE / Starlink integration, multi-WAN routing, failover, WireGuard overlay, QoS |
| 03 | [Raspberry Pi 5 Companion Manual](docs/03-pi5-companion-computer.md) | Provisioning, OS, services, cameras, power, thermal, udev, images |
| 04 | [Flight Control Stack](docs/04-flight-control-stack.md) | ArduPilot/PX4, MAVLink router, serial/UART setup, parameters, canbus |
| 05 | [Teleoperation](docs/05-teleoperation.md) | Gamepad/joystick control, video return, latency budget, lost-link behavior |
| 06 | [Autonomous Operations](docs/06-autonomous-operations.md) | Missions, offboard, MAVSDK/ROS 2, geofencing, precision, safety layers |
| 07 | [Security Hardening](docs/07-security-hardening.md) | WireGuard, MAVLink signing, TLS, identity, disk & boot security |
| 08 | [Operations Manual](docs/08-operations-manual.md) | Preflight, launch, in-flight, recovery, checklists, EMERGENCY procedures |
| 09 | [Troubleshooting & Maintenance](docs/09-troubleshooting.md) | Fault trees, diagnostics, link tuning, logs |

## Configuration files

| Path | Purpose |
|------|---------|
| [`configs/netplan/01-links.yaml`](configs/netplan/01-links.yaml) | Base wired/Wi-Fi/LTE interface configuration |
| [`configs/networkmanager/`](configs/networkmanager/) | LTE/Starlink/WireGuard connection profiles |
| [`configs/wireguard/`](configs/wireguard/) | Drone and ground/VPS WireGuard configs |
| [`configs/mavlink-router/main.conf`](configs/mavlink-router/main.conf) | MAVLink endpoint routing |
| [`configs/systemd/`](configs/systemd/) | `mavlink-router`, `wan-failover`, video, telemetry units |
| [`configs/scripts/`](configs/scripts/) | Failover, provisioning, health-check, launch scripts |
| [`configs/udev/99-flight-controller.rules`](configs/udev/99-flight-controller.rules) | Stable device names for FC / modem / cameras |
| [`configs/px4/`](configs/px4/) | Flight-controller parameter baselines |

---

## Quick start (TL;DR)

```bash
# On a fresh Raspberry Pi 5 running Ubuntu Server 24.04 (arm64):
git clone <this-repo> ~/uacom
cd ~/uacom
sudo ./configs/scripts/companion-provision.sh        # base OS, users, hardening
sudo ./configs/scripts/install-stack.sh              # mavlink-router, wireguard, tools
sudo cp configs/mavlink-router/main.conf   /etc/mavlink-router/main.conf
sudo cp configs/systemd/*.service          /etc/systemd/system/
sudo cp configs/netplan/01-links.yaml      /etc/netplan/01-links.yaml
sudo cp configs/udev/99-flight-controller.rules /etc/udev/rules.d/
sudo cp configs/scripts/wan-failover.sh    /usr/local/sbin/
sudo netplan apply
sudo systemctl daemon-reload
sudo systemctl enable --now mavlink-router wan-failover wg-quick@wg0
```

See [doc 03](docs/03-pi5-companion-computer.md) for the full, verified walkthrough.

---

## Regulatory & safety notice

Operating BVLOS / autonomous aircraft is **regulated**. Before flying:
- Hold the required operator/remote-pilot certificates for your jurisdiction
  (e.g. FAA Part 107 + waivers, EASA specific category / SORA, CAA).
- Obtain BVLOS, over-people, and airspace authorizations as applicable.
- Keep a **human in the loop** with an independent **terminate-flight** capability that
  does not traverse the primary command link.
- Never operate a command-and-control link without a validated **lost-link failsafe** and
  **geofence**. Test failsafes on the bench and in a controlled area first.

This repository is a technical reference for lawful, professional UAS engineering. It is
the operator's responsibility to comply with all applicable law.
