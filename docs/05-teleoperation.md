# 05 — Teleoperation (No RC Transmitter)

Teleoperation means **manual flight via an IP link and a gamepad/joystick at the GCS**,
with no RC transmitter and no receiver in the aircraft.

## 1. Control path

```
Joystick/gamepad (GCS)
   │  input events
   ▼
GCS teleop app (MAVSDK / MAVProxy / custom)
   │  MANUAL_CONTROL  (or RC_CHANNELS_OVERRIDE) @ 20–50 Hz
   ▼
UDP 14550 over wg0
   ▼
mavlink-router (aircraft)
   ▼
FC  (GUIDED/manual-control setpoints → stabilized → motors)
```

MAVLink messages:
- `MANUAL_CONTROL` — normalized axes/buttons; preferred (maps to non-RC manual).
- `RC_CHANNELS_OVERRIDE` — raw channel emulation; use only if the FC needs RC-style.
- `SET_ATTITUDE_TARGET` / `SET_POSITION_TARGET_*` — for stick-to-attitude rates (advanced).

## 2. Latency budget (hard requirements)

| Segment | Budget |
|---------|--------|
| Joystick polling | ≤ 20 ms |
| GCS app → UDP | ≤ 10 ms |
| Network RTT (one-way ×2) | ≤ 100 ms (**Wi-Fi**); LTE/Starlink make true manual flight dangerous |
| FC ingest → actuator | ≤ 40 ms |
| **End-to-end** | **≤ 150 ms** for acceptable manual feel |

> **Reality check:** Manual (stick) flight over LTE/Starlink is generally **not safe**
> due to latency and jitter. Design teleop as **Wi-Fi-local** or **velocity/command
> based** (see §4) for wide-area. Use autonomy + supervisory override for BVLOS.

## 3. Joystick configuration

### 3.1 Identify the device
```bash
ls /dev/input/js*           # legacy joystick API
cat /proc/bus/input/devices # find the gamepad
jstest /dev/input/js0       # live axis view (joydev tools)
```

### 3.2 Map axes in the GCS
- Typically: Yaw = left X, Throttle/Climb = left Y, Pitch = right Y, Roll = right X.
- Set **deadbands** (3–5 %) and **expo** (0.3–0.5) for smooth center feel.
- Bind an **arm/disarm** button (with a two-step confirm in software) and a
  **mode switch** (Manual/Position/Auto/RTL).
- Bind a **deadman/kill** action mapped to a non-IP termination path.

### 3.3 Example: QGroundControl
- Settings → Joystick → calibrate → assign actions → enable.
- Set `Manual control` mode and ensure the vehicle is in `GUIDED` (ArduPilot) or a
  supported manual mode.

### 3.4 Example: MAVSDK-Python teleop skeleton
```python
import asyncio
from mavsdk import System
from mavsdk.manual_control import ManualControl

async def main():
    drone = System()
    await drone.connect(system_address="udp://:14540")  # local GCS router

    async for state in drone.core.connection_state():
        if state.is_connected:
            break

    mc = ManualControl(drone)
    # axes in [-1, 1]; buttons bitmask
    await mc.set_manual_control_input(
        x=0.0, y=0.0, z=0.0, r=0.0
    )

asyncio.run(main())
```

## 4. Wide-area supervisory teleoperation

For LTE/Starlink, do **not** send raw sticks. Use:

1. **Velocity/position commands** (`SET_POSITION_TARGET_LOCAL_NED` with velocity) —
   tolerant of latency; the FC stabilizes.
2. **Waypoint-on-demand** ("go to this point", "hold here", "orbit") — click-to-fly.
3. **Mode/altitude/heading nudges** via `COMMAND_LONG`.
4. **Autonomy executes; operator supervises** and can abort/RTL/divert.

This converts latency sensitivity from the control loop into discrete commands.

## 5. Lost-link behavior (critical)

| Condition | Detection | Action |
|-----------|-----------|--------|
| C2 lost < 1 s | packet gap | hold last command, FC stabilizes |
| C2 lost > `FS_GCS_TIMEOUT` | no heartbeat | **RTL** (or configured `FS_ACTION`) |
| Teleop app crash | no `MANUAL_CONTROL` | FC failsafe |
| Offboard stale (PX4) | setpoint timeout | `COM_OBL_ACT` |
| Video lost but C2 good | stream gap | continue; fly by telemetry |

Design rule: **losing the operator must never produce uncontrolled flight.** The FC
failsafe, not the GCS, is the backstop.

## 6. Video-return integration

- GCS shows video (UDP 5600) next to the map/telemetry.
- Add a **video timestamp** and a synthetic delay overlay so operators do not
  over-trust the image.
- If video freezes, telemetry-attitude HUD must remain authoritative.

## 7. Rate & jitter control

- Send `MANUAL_CONTROL` at a fixed 50 Hz over Wi-Fi, 20 Hz over LTE, 10 Hz over
  Starlink (if used at all).
- Use a monotonic clock; drop late samples rather than queueing them.
- Never let a queue build — stale stick inputs are worse than no input.

## 8. Bench validation

1. FC powered, props **off**, GCS teleop live.
2. Confirm all axes move the correct surface/motor mixer (motor test / servo view).
3. Kill the network mid-stick → confirm FC failsafe behavior.
4. Verify deadman/kill button independent of IP.
5. Measure end-to-end latency (loopback inject → telemetry echo).

Continue to **[06 — Autonomous Operations](06-autonomous-operations.md)**.
