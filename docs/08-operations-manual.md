# 08 — Operations Manual

Field procedures for operating the aircraft over Wi-Fi / LTE / Starlink with **no RC
transmitter**. Adapt to your jurisdiction, aircraft, and crew.

## 1. Roles

| Role | Responsibility |
|------|----------------|
| Remote Pilot (RP) | Command authority; teleop/supervision; abort |
| Observer (VO) | Visual scan, airspace, RTL/terminate backup |
| Ground/Crew | Link management, power, safety perimeter |

Minimum crew for BVLOS: **RP + VO**, with an independent terminate path.

## 2. Preflight (before power)

- [ ] Airworthiness: props, frame, motors, wiring, antennae secured.
- [ ] Batteries charged; measured voltage; C-rating adequate.
- [ ] BEC/power for Pi verified (5 V/5 A), no shared noisy rail.
- [ ] FC ↔ Pi UART connected, `/dev/fc` present, baud matched.
- [ ] 5 GHz antennae, LTE SIM/APN, Starlink terminal connected.
- [ ] SD/NVMe free space, logs writable.
- [ ] Firmware/params version matches the approved baseline.
- [ ] Geofence and failsafe params confirmed (uploaded, verified).
- [ ] Independent terminate mechanism tested (safe area).
- [ ] Airspace/authorization (NOTAM/BVLOS/over-people) current.
- [ ] Weather: wind, precipitation (Starlink/5 GHz degrade), visibility.

## 3. Power-up sequence

1. **GCS first** (ground laptop, WireGuard up, GCS app open).
2. **Aircraft** power on (Pi boots; `mavlink-router` starts; `wg-quick@wg0` up).
3. Confirm **FC heartbeat** in GCS (sysid 1, ≥1 Hz).
4. Confirm **overlay** (`wg show`, `ping 10.8.0.10`) and **active WAN** state.
5. Confirm **video** (if used).
6. Confirm **telemetry** attitude/position/battery sane.

## 4. Preflight checks (software)

```bash
# on aircraft
sudo wg show
cat /run/wan-failover/state.json
sudo systemctl is-active mavlink-router video-tx companion-health
vcgencmd get_throttled          # expect 0x0
ls -l /dev/fc
```
- [ ] All services active.
- [ ] Active link is the intended one (Wi-Fi for local).
- [ ] No thermal throttling.
- [ ] Battery health and cell voltages within limits.
- [ ] GPS fix, HDOP acceptable, EKF healthy (**wait for EKF** after power-up; do not
      arm prematurely).

## 5. Link verification

| Check | Command | Expect |
|-------|---------|--------|
| Overlay | `ping -c5 10.8.0.20` | replies, low RTT |
| C2 | GCS heartbeat | stable, no gaps |
| Teleop | Move sticks (props off) | correct response |
| Latency | app/link RTT | ≤ 150 ms on Wi-Fi |
| Failover | temporarily disable active WAN | standby takes over |

## 6. Launch

1. Announce takeoff; clear the safety perimeter.
2. Arm via GCS (**two-step confirmation**).
3. Takeoff to a low hover; verify stability and link.
4. Confirm **failsafe mode is configured** before departure.
5. Transition to the mission/teleop as planned.

## 7. In-flight monitoring

Continuously monitor:
- **Link** (active WAN, RSSI/RSRP/signal, handshake age, latency/jitter).
- **Video** health (frame rate, bitrate vs. link).
- **Power** (battery %/voltage, current).
- **Thermal** (Pi temperature, throttle flags).
- **Attitude/position/EKF**, GPS sats.
- **Airspace/obstacles** via VO.

Abort/divert thresholds should be pre-briefed (e.g. battery < 30 %, link degraded for
> 10 s on the primary, geofence approach).

## 8. Link degradation playbook

| Symptom | Action |
|---------|--------|
| Wi-Fi RSSI low | Reduce range, climb for LoS, or accept LTE failover |
| LTE congestion | Switch to Starlink or reduce telemetry/video |
| Starlink high latency | Only use for supervision; avoid manual |
| Video stuttering | Lower bitrate; prioritize C2 |
| C2 gaps | Hold/loiter; confirm failsafe armed; prepare RTL |
| Both wide-area links lost | RTL/land per plan; independent terminate ready |

## 9. Recovery / landing

1. Command RTL or fly a manual approach (Wi-Fi local ideally).
2. Descend, hover, land; disarm.
3. **Power down aircraft first**, then GCS (preserve logs).
4. Secure the area; make the aircraft safe (props).

## 10. Postflight

- [ ] Download `.tlog`, MAVLink telemetry log, companion journal, video.
- [ ] Note anomalies, link metrics, battery consumed.
- [ ] Inspect airframe, props, connectors, antennae.
- [ ] Charge/store batteries per spec.
- [ ] Sync logs to ground; back up and archive.
- [ ] If any failsafe fired, investigate before next flight.

## 11. EMERGENCY procedures

> Practice these. In an emergency, act first, document after.

| Emergency | Immediate action |
|-----------|------------------|
| **Loss of C2** | FC failsafe → RTL/Loiter. If FC failsafe not configured, independent terminate. VO maintains visual. |
| **Flyaway** | Activate **independent terminate** (non-IP). Do not chase. |
| **GCS failure** | Aircraft continues failsafe/autonomy. Reboot GCS; do not re-command blindly. |
| **Battery fire** | Land immediately, cut power, evacuate upwind, use appropriate extinguisher. |
| **Loss of GPS** | Expect Attitude/AltHold; fly conservatively; land. |
| **Compass/EKF fault** | Switch to a safe manual mode if available; land. |
| **Airspace conflict** | Give way; descend; follow right-of-way; notify ATC if required. |
| **Regulatory/observer alert** | Abort mission; RTL. |
| **Overheat (Pi)** | Reduce video; if sustained, land. |
| **Unauthorized control** | Independent terminate; treat as security incident (doc 07). |

## 12. Crew resource management

- **Brief** before flight: mission, links, failsafes, abort criteria, emergency plan.
- **Callouts**: "Link degraded", "RTL", "Terminate", "Clear".
- **Sterile cockpit** during critical phases.
- **No single point of authority failure**: VO can call abort.

Continue to **[09 — Troubleshooting & Maintenance](09-troubleshooting.md)**.
