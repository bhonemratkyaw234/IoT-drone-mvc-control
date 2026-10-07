# 01 — System Architecture

## 1. Design goals

| Goal | Mechanism |
|------|-----------|
| Resilient C2 across 3 link types | Multi-WAN + WireGuard overlay |
| Low-latency teleop | Separate control flow, QoS, Wi-Fi preference |
| Graceful degradation | Failover order, bandwidth-aware video |
| Autonomy on board | ROS 2 / MAVSDK, offboard setpoints |
| Failsafe-first | FC failsafes + companion health supervisor |
| Observability | Structured logs, remote telemetry, blackbox |
| Security | WireGuard, MAVLink signing, least privilege |

## 2. High-level architecture

```
                         ┌──────────────────────────────────────────┐
                         │            GROUND SEGMENT                │
                         │                                          │
                         │  ┌───────────┐   ┌───────────────────┐   │
                         │  │  GCS app  │   │  Joystick/gamepad  │   │
                         │  │ (QGC/     │◄──┤  (teleop input)    │   │
                         │  │  MAVSDK)  │   └───────────────────┘   │
                         │  └─────┬─────┘                            │
                         │        │ MAVLink over UDP (wg0)           │
                         │  ┌─────▼─────┐   ┌───────────────────┐   │
                         │  │ WireGuard │   │ Optional: VPS hub │   │
                         │  │  ground   │◄──┤  (public IP, wg)  │   │
                         │  └─────┬─────┘   └───────────────────┘   │
                         │        │                                  │
                         │  ┌─────▼──────────────────────────────┐  │
                         │  │ Ground access (Wi-Fi / LTE / Eth) │  │
                         │  └───────────────────────────────────┘  │
                         └───────────────┬──────────────────────────┘
                                         │
                ═══ physical links (5 GHz Wi-Fi / 4G LTE / Starlink) ═══
                                         │
                         ┌───────────────▼──────────────────────────┐
                         │            AIRBORNE SEGMENT               │
                         │                                          │
                         │  ┌────────────────────────────────────┐  │
                         │  │ Raspberry Pi 5 companion           │  │
                         │  │  ┌────────────┐  ┌──────────────┐  │  │
                         │  │  │WireGuard   │  │wan-failover  │  │  │
                         │  │  │ (wg0)      │  │ supervisor   │  │  │
                         │  │  └─────┬──────┘  └──────┬───────┘  │  │
                         │  │        │                │          │  │
                         │  │  ┌─────▼────────────────▼───────┐  │  │
                         │  │  │        mavlink-router         │  │  │
                         │  │  └───┬───────┬──────────┬────────┘  │  │
                         │  │      │       │          │           │  │
                         │  │  ┌───▼──┐ ┌──▼───┐ ┌────▼─────┐      │  │
                         │  │  │ UART │ │ USB  │ │ Video    │      │  │
                         │  │  │ /dev/│ │ cam  │ │ pipeline │      │  │
                         │  │  │ ttyAMA│ │      │ └──────────┘      │  │
                         │  │  └───┬──┘ └──────┘                    │  │
                         │  └──────┼───────────────────────────────┘  │
                         │         │ MAVLink (serial)                 │
                         │  ┌──────▼─────────────────────────────┐    │
                         │  │ Flight Controller (ArduPilot/PX4)  │    │
                         │  │  EKF · failsafe · geofence · RTL   │    │
                         │  └──────┬─────────────────────────────┘    │
                         │         │ DShot/PWM · CAN                  │
                         │  ┌──────▼─────────────────────────────┐    │
                         │  │ ESCs · motors · servos · payload   │    │
                         │  └────────────────────────────────────┘    │
                         └──────────────────────────────────────────┘
```

## 3. Link topology & failover order

**Default preference (configurable):**

```
1. 5 GHz Wi-Fi     (eth/wlan)  — lowest latency; used when in range
2. 4G LTE          (wwan)      — wide-area primary
3. Starlink        (eth1)      — high latency, long range / backup
```

Rationale: prefer the *lowest-latency* link that is healthy, and keep the others warm
for failover. Metrics are set by the failover daemon, not by hand, so ordering is
deterministic and observable.

```
                    ┌───────────────────────────┐
                    │     wan-failover daemon    │
                    │  probes each WAN's health  │
                    └──────┬───────┬───────┬─────┘
                           │       │       │
             metric 100 ┌──▼──┐ ┌──▼──┐ ┌──▼──┐
              (best)    │wlan0│ │wwan0│ │eth1 │
                        │Wi-Fi│ │ LTE │ │Star │
                        └─────┘ └─────┘ └─────┘
                 priority:  1       2       3
```

Each WAN gets a health probe (ICMP + TCP + DNS + WireGuard handshake age). If the
active link degrades beyond thresholds, the daemon bumps its route metric and the next
healthy link takes over **without** re-establishing the overlay (WireGuard is
link-agnostic — it roams).

See [doc 02](02-network-routing.md) for the full routing/failover design.

## 4. Software component inventory (airborne)

| Component | Role | Default port/socket |
|-----------|------|---------------------|
| `mavlink-router` | MAVLink fan-out/merge | UDP 14550, TCP 5760, UART |
| `wg-quick@wg0` | Overlay VPN | UDP 51820 |
| `wan-failover` | WAN health + route metrics | — |
| `mavlink-router` health | FC heartbeat watchdog | — |
| `video-tx` (GStreamer) | Camera→GCS stream | UDP 5600 |
| `companion-health` | Thermal/power/disk supervisor | — |
| Autonomy (`mavsdk`/ROS 2) | Missions, offboard | local |
| `systemd` units | Supervision, restart | — |

## 5. Data flows

### 5.1 Telemetry downstream (air → ground)
FC → UART → `mavlink-router` → `wg0` → GCS/UDP 14550.

### 5.2 Command upstream (ground → air), teleop
GCS/joystick → `wg0` → `mavlink-router` → FC. Manual-control setpoints
(`MANUAL_CONTROL` / `RC_CHANNELS_OVERRIDE`) arrive at 20–50 Hz.

### 5.3 Video
Camera → `libcamera`/GStreamer → H.264/H.265 → UDP 5600 → `wg0` → GCS.
Adaptive bitrate drops when the active link is LTE.

### 5.4 Autonomy
Onboard autonomy → `mavsdk`/MAVSDK → FC (Offboard/Guided). GCS can still monitor and
override. All setpoints pass the FC's own limits.

## 6. Redundancy model

| Layer | Primary | Redundant | Failover trigger |
|-------|---------|-----------|------------------|
| Physical link | Wi-Fi | LTE, Starlink | probe failure / metric |
| Overlay | wg0 (roaming) | — (single overlay) | re-handshake |
| Companion | Pi 5 | optional 2nd Pi / FC direct | heartbeat loss |
| MAVLink path | UART | USB/UDP to FC | `mavlink-router` re-route |
| Flight control | FC | — (authoritative) | FC failsafe |
| Termination | — | independent RF/kill | operator action |

> **Note on "single overlay":** WireGuard is the correct choice here because it roams
> across IP changes without tearing down the tunnel. It is one logical network over
> three physical paths.

## 7. Failure modes & responses

| Failure | Detection | Response |
|---------|-----------|----------|
| Wi-Fi loss | probe + route | switch to LTE (metric) |
| LTE loss | probe | switch to Starlink |
| All IP links down | `mavlink-router` FC heartbeat proxy | FC triggers `GCS failsafe` → RTL/Loiter |
| GCS crash | companion detects no GCS heartbeat | FC failsafe (or autonomy holds position) |
| Pi 5 hang | FC heartbeat timeout | FC failsafe |
| Overheating | `companion-health` | reduce video, throttle, warn |
| Low disk | `companion-health` | rotate/stop logging, warning |
| Command injection attempt | MAVLink signing | reject unsigned packets |

## 8. Interfaces & contracts

- **MAVLink over UDP 14550** on `wg0`: system id `1` for FC, `255` for GCS.
- **MAVLink signing**: enabled; key provisioned out of band (see doc 07).
- **Video**: UDP 5600, RTP/H.264.
- **Health telemetry**: JSON over MQTT/HTTP to a monitoring endpoint (optional).

## 9. Deployment tiers

| Tier | Description |
|------|-------------|
| Bench | Everything on one network, no radio, validate software |
| Local ops | 5 GHz Wi-Fi primary, LTE warm standby |
| BVLOS regional | LTE primary, Starlink standby/assist |
| Remote/over-water | Starlink primary, LTE where available |

Continue to **[02 — Network & Routing](02-network-routing.md)**.
