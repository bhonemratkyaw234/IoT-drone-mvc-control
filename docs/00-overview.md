# 00 — Overview & Concepts

## 1. What this system is

A **transmitter-less UAS command and control (C2) architecture**. Instead of a 2.4 GHz
RC link carrying PWM channels, the aircraft carries a Linux **companion computer**
(Raspberry Pi 5) that:

1. Hosts one or more **IP data links** (5 GHz Wi-Fi, 4G LTE, Starlink).
2. Bridges those links into a single resilient **overlay network** (WireGuard).
3. Routes **MAVLink** telemetry/command between the flight controller and the ground
   control station (GCS).
4. Streams **video** back to the operator.
5. Runs **autonomy** and **teleoperation** logic.

The flight controller (FC) still enforces the real safety envelope: failsafes, geofence,
attitude limits, and RTL. The companion never replaces that; it augments it.

## 2. Why no RC transmitter

| Driver | Benefit |
|--------|---------|
| BVLOS range | IP links (LTE/Starlink) reach far beyond 2.4 GHz LoS |
| Single operator | Video + control + mission in one GCS |
| Data richness | Telemetry logs, payload data, fleet management |
| Autonomy | Native MAVLink mission/offboard interfaces |
| Regulatory | C2 link can be logged/authenticated (MAVLink2 signing) |

The cost is added complexity and dependency on the companion + link stack — which is
exactly what this documentation de-risks.

## 3. Reference stack

```
Ground Control Station (GCS)          Airborne
┌───────────────────────────┐         ┌────────────────────────────────────┐
│ QGroundControl /          │◄═══════►│ Raspberry Pi 5 (companion)         │
│ custom MAVSDK app         │  C2 +   │  • mavlink-router                  │
│ Joystick (teleop)         │  video  │  • WireGuard overlay                │
│ WireGuard peer            │         │  • video pipeline                   │
└───────────────────────────┘         │  • autonomy (ROS 2 / MAVSDK)        │
                                      └───────────────┬────────────────────┘
                                                      │ UART / USB / CAN
                                      ┌───────────────▼────────────────────┐
                                      │ Flight Controller (ArduPilot/PX4)  │
                                      │  failsafes, geofence, EKF, RTL     │
                                      └───────────────┬────────────────────┘
                                                      │ DShot / PWM
                                                  ESCs + motors
```

## 4. Links at a glance

| Attribute | 5 GHz Wi-Fi | 4G LTE | Starlink |
|-----------|-------------|--------|----------|
| Typical RTT | 2–15 ms | 30–70 ms | 25–80 ms (varies) |
| Throughput | 20–300 Mbps | 2–50 Mbps | 20–200 Mbps |
| Range | 0.1–20+ km (antenna-dependent) | tens of km (cell) | continental |
| Regulatory | License-exempt / licensed band | Carrier SIM / APN | Carrier subscription |
| NAT/CGNAT | Usually no | Almost always | Always (no inbound) |
| Best for | Bench, local, high-rate video | Mobile wide-area | Remote/over-water, backup |
| Weakness | Needs LoS | Coverage gaps, jitter | Latency, obstructions, CGNAT |

**Key consequence:** LTE and Starlink sit behind **carrier-grade NAT**, so the ground
station generally *cannot* open a listening port on the aircraft. The overlay
**WireGuard hub-and-spoke** (or a VPS rendezvous) solves this: both ends dial **out**.

## 5. Latency & bandwidth budget (design targets)

| Flow | Bandwidth | Max acceptable latency |
|------|-----------|------------------------|
| MAVLink telemetry (2 Hz status, 10–50 Hz attitude) | 5–50 kbps | 250 ms |
| Teleop command ingress (manual control @ 20–50 Hz) | 10–60 kbps | 150 ms (**hard**) |
| Command acknowledgement / mode | <5 kbps | 250 ms |
| HD video 720p (optional) | 1–4 Mbps | 300 ms |
| HD video 1080p (optional) | 4–8 Mbps | 300 ms |

Design the **C2 path separately from video** (separate flow, DSCP/priority) so video
congestion never starves control. See [doc 02 §QoS](02-network-routing.md#8-qos--traffic-shaping).

## 6. Safety philosophy

1. **The flight controller is authoritative.** Autonomy and teleop are *inputs* to it.
2. **Fail safe, then fail silent.** On link loss the FC runs RTL/Loiter/Land per a
   configured failsafe; it does not wait for the operator.
3. **Independent termination.** A dedicated, always-available terminate mechanism
   (e.g. an RF kill/arming switch or an FC "terminate" action) must not depend on the
   IP link stack. This is mandatory for serious BVLOS work.
4. **Defense in depth.** Multiple links, multiple autonomy fallbacks, geofence, battery
   and engine failsafes, explicit arming rules.
5. **Test everything on the bench.** Simulate link loss by pulling the modem, not just
   by toggling a flag.

## 7. Glossary

- **GCS** — Ground Control Station.
- **FC** — Flight Controller (Pixhawk-class autopilot).
- **MAVLink** — Lightweight binary protocol for telemetry/command between FC and GCS.
- **mavlink-router** — Daemon that fans MAVLink between serial, UDP, and TCP endpoints.
- **CGNAT** — Carrier-Grade NAT; blocks inbound connections.
- **BVLOS** — Beyond Visual Line Of Sight.
- **RTL** — Return To Launch.
- **Offboard mode** (PX4) / **Guided mode** (ArduPilot) — External computer supplies setpoints.
- **Overlay** — VPN network layer (WireGuard) spanning the physical links.
- **DSCP** — IP header field used for QoS classification.

Continue to **[01 — System Architecture](01-system-architecture.md)**.
