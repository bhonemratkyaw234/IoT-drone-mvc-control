# 06 — Autonomous Operations

## 1. Modes of autonomy

| Mode | Interface | Use |
|------|-----------|-----|
| Mission (waypoints) | MAVLink `MISSION_*` | Survey, patrol, cargo |
| Offboard/Guided setpoints | `SET_POSITION_TARGET_*` | Velocity/position tracking, vision servoing |
| Geofenced auto | FC geofence | Contained operations |
| Supervised autonomy | Autonomy + operator abort | BVLOS with human oversight |
| Full autonomy | Onboard decision | Only with proven safety case |

## 2. Onboard autonomy stack options

### 2.1 MAVSDK (lightweight)
Best for scripted missions, monitoring, and supervisory logic.
```python
import asyncio
from mavsdk import System

async def mission():
    drone = System()
    await drone.connect(system_address="udp://:14540")
    async for state in drone.core.connection_state():
        if state.is_connected:
            break
    await drone.action.arm()
    await drone.action.takeoff()
    await asyncio.sleep(2)
    # upload/mission or goto
    await drone.action.goto_location(47.3977, 8.5456, 10.0, 0.0)
    while True:
        async for pos in drone.telemetry.position():
            print(pos.latitude_deg, pos.longitude_deg, pos.relative_altitude_m)
            break
        await asyncio.sleep(1)

asyncio.run(mission())
```

### 2.2 ROS 2 (heavy, feature-rich)
For perception, SLAM, obstacle avoidance. Bridge via `px4_msgs`/`mavros`.
- PX4: `micro-ROS`/uXRCE-DDS or `mavros`.
- ArduPilot: `mavros` or `ap_dds`.
- Keep the ROS graph isolated from the C2 network; route only what is needed over
  `wg0`.

### 2.3 Hybrid (recommended for BVLOS)
Autonomy plans and flies; the GCS **supervises**: monitor, abort, divert, RTL. The human
retains authority.

## 3. Offboard (PX4) / Guided (ArduPilot) setpoint rules

- **PX4:** require a setpoint stream **> 2 Hz** before `OFFBOARD` will engage; the FC
  exits offboard on timeout per `COM_OBL_ACT`.
- **ArduPilot:** `GUIDED` accepts targeted commands; velocity (`SET_POSITION_TARGET`
  with `type_mask` velocity bits).
- Always start offboard from a **stable hover** and with a **fallback mode** set.
- Never let an autonomy node take off or arm without operator confirmation unless
  your safety case explicitly allows it.

## 4. Geofencing

Layered fencing:
1. **FC fence** (`FENCE_*` / `GF_*`) — hard, independent of link.
2. **Autonomy geofence** — pre-planning, softer.
3. **GCS fence** — operator warning.

```python
# MAVSDK: induce a geofence breach for testing
await drone.param.set_param_int("FENCE_ENABLE", 1)
```

Test the fence by commanding a waypoint outside it and verifying the FC action.

## 5. Mission planning

- Build in QGC / MAVSDK; store as `.plan` / `.waypoints`.
- Validate terrain clearance and battery vs. distance (with margin).
- Set **RTL after mission**, and a **rally point** if supported.
- Include hold points for link reacquisition on LTE/Starlink.

## 6. Safety layers (defense in depth)

```
Layer 5  Operator terminate (independent RF/kill)
Layer 4  GCS abort / divert / RTL button
Layer 3  Autonomy failsafe (lost link -> hold/return)
Layer 2  FC failsafes (GCS, battery, fence, EKF)
Layer 1  Firmware/attitude/rate limits
```

Every layer must be **tested** and **independent where possible**.

## 7. Precision & payload autonomy

- RTK/PPK for cm-level positioning (survey, mapping).
- Gimbal control (`GIMBAL_MANAGER_*`).
- Camera trigger (`CAMERA_TRIGGER`) for photogrammetry.
- Precision landing (ArduPilot `PLND_*`, PX4 `PLD_*`) — test with a target.

## 8. Behavior on C2 degradation

| Link quality | Autonomy behavior |
|--------------|-------------------|
| Good | Full remote supervision |
| Degraded (LTE) | Reduce telemetry rate, hold plan, notify operator |
| Lost | Continue mission if pre-authorized, else RTL |
| Return of link | Resume supervision, sync state |

Onboard autonomy must be **fail-operational** for the pre-authorized envelope and
**fail-safe** otherwise.

## 9. Testing & simulation

- **SITL** (ArduPilot/PX4) with MAVSDK/ROS 2 and a simulated link (delay/jitter via
  `tc netem`) before real flight.
- Link simulation: add 50–300 ms delay + 5 % loss on `wg0`/dummy and re-run autonomy.
- HIL only when hardware-in-loop is required.

```bash
# simulate a poor LTE link on an interface (test only)
sudo tc qdisc add dev wg0 root netem delay 60ms 20ms loss 2%
```

## 10. Data & logs

- MAVLink `.tlog` for full C2 history.
- Onboard rosbag / MAVSDK logs.
- Sync to ground on link recovery.
- Retain per regulatory requirements (often 3+ months).

Continue to **[07 — Security Hardening](07-security-hardening.md)**.
