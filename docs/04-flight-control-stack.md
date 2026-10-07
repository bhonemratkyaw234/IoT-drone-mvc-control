# 04 — Flight Control Stack

The flight controller (FC) is the **authoritative** safety element. The companion
computer supplies commands and telemetry but never bypasses FC limits.

## 1. Supported autopilots

| Autopilot | Firmware | External-control mode | Notes |
|-----------|----------|-----------------------|-------|
| Pixhawk 6X / 6C | ArduPilot (Copter/Plane) | `GUIDED` | Mature failsafes |
| Pixhawk 6X | PX4 | `OFFBOARD` | Clean offboard setpoints |
| CubePilot Cube Orange+ | ArduPilot / PX4 | `GUIDED` / `OFFBOARD` | Redundant IMUs |
| Holybro / Matek (small) | ArduPilot | `GUIDED` | Lightweight builds |

Choose **one** and stay consistent across the fleet. This doc gives **ArduPilot** as the
primary and notes PX4 equivalents.

## 2. Companion ↔ FC wiring

```
Pi 5 GPIO14 (TXD) ─► FC RX
Pi 5 GPIO15 (RXD) ◄─ FC TX
Pi 5 GND         ── FC GND
(optional) Pi 5 GPIO ... ─► FC safety/arm output  (independent termination)
```

- Baud: `921600` (recommended) or `1500000`.
- Use a level-safe connection (most FCs are 3.3 V TTL; Pi is 3.3 V — direct is fine,
  verify with a meter).
- Add a series resistor / short wire; keep runs < 30 cm.

## 3. MAVLink configuration

### 3.1 ArduPilot serial port (example `SERIAL2` = TELEM2)
```
SERIAL2_PROTOCOL = 2        # MAVLink2
SERIAL2_BAUD     = 921
```
Where `921` = 921600 baud (ArduPilot uses `921` for 921600).

### 3.2 PX4 serial port (example `TELEM2`)
```
MAV_1_CONFIG = TELEM2
MAV_1_MODE   = Onboard      # companion-link mode
SER_TEL2_BAUD = 921600
```

### 3.3 Stream rates

Ensure useful telemetry on the companion link (ArduPilot `SR2_*`, PX4 `MAV_x_RATE_*`):
```
SR2_EXTRA1 = 10   # attitude
SR2_POSITION = 5
SR2_EXTRA2 = 10   # vfr_hud
SR2_EXT_STAT = 2
SR2_EXTRA3 = 2
```

## 4. Failsafes (mandatory)

Configure **all** of these and test each on the bench.

### 4.1 ArduPilot
```
FS_GCS_ENABL   = 1      # GCS failsafe enabled (no MAVLink heartbeat from companion)
FS_GCS_TIMEOUT = 5      # seconds (tune; consider link RTT)
FS_ACTION      = 1      # RTL  (or 2=Loiter, 3=Land -- choose per ops)
FS_THR_ENABLE  = 1      # throttle failsafe
FS_THR_VALUE   = 975
FENCE_ENABLE   = 1
FENCE_TYPE     = 7      # alt+circle+polygon
FENCE_ACTION   = 1      # RTL
FENCE_ALT_MAX  = 120    # metres (jurisdiction-dependent)
FENCE_RADIUS   = 500
RTL_ALT        = 6000   # cm (60 m)
BATT_FS_LOW_ACT  = 2    # RTL
BATT_FS_CRT_ACT  = 1    # Land
```

### 4.2 PX4
```
NAV_RCL_ACT     = 2     # Return mode on RC loss (N/A if no RC)
NAV_DLL_ACT     = 2     # data-link loss -> Return
COM_DL_LOSS_T   = 10
COM_OBL_ACT     = 2     # offboard loss -> Hold/Return
COM_OBL_RC_ACT  = 2
GF_ACTION       = 1     # geofence RTL
GF_MAX_HOR_DIST = 500
GF_MAX_VER_DIST = 120
```

> **No-RC implication:** with no RC transmitter, `NAV_RCL_ACT` may be irrelevant, but
> **`NAV_DLL_ACT` (data-link loss)** and **`COM_OBL_ACT` (offboard loss)** are the
> critical ones. Set them explicitly and verify.

## 5. Arming & safety switch

- If a hardware safety switch is fitted, decide who owns it (operator/manual).
- Enable **arm checks** (`ARMING_CHECK = 1`) and do not blanket-disable.
- Consider `ARMING_CHECK` bits so GPS/EKF/battery checks remain.
- Independent termination: wire a dedicated **kill/terminate** input (e.g. an FC AUX
  channel mapped to an action, or a power kill on a controlled relay) that does **not**
  traverse IP. Document it in the operations manual.

## 6. EKF / sensor health

- Require EKF variance and innovation checks before arming (`EK3_*`).
- GPS: use RTK/dual-GPS where available; `GPS_HDOP` and sats as preflight gates.
- Vibration: soft-mount the FC; monitor `VIBE` and clamp.

## 7. Compass / IMU

- Calibrate on the vehicle after final wiring.
- Keep the FC away from high-current wiring and the LTE modem (RFI).
- Re-verify after adding the Starlink/LTE antennas.

## 8. CAN / DroneCAN (optional)

For CAN ESCs, airspeed, GPS, or power modules:
```
CAN_P1_DRIVER = 1
CAN_D1_PROTOCOL = 1     # DroneCAN
```
Use a CAN terminator at both ends; keep bus < 1 m at 1 Mbit/s.

## 9. Parameter baselines

Reference parameter files:
- [`configs/px4/px4-airframe.params`](../configs/px4/px4-airframe.params)
- [`configs/px4/px4-c2.params`](../configs/px4/px4-c2.params) (link failsafes)
- ArduPilot parameters documented inline in this file; produce a `.param` from your FC.

Load and verify:
```bash
# PX4
mavparam set MAV_1_CONFIG TELEM2   # or via QGC
# ArduPilot
mavproxy.py --master=/dev/fc --baudrate=921600
param load baseline.param
param show FS_GCS_ENABL
```

## 10. Firmware update

- Update FC firmware **on the bench**, never in the field unless required.
- Keep a known-good firmware + parameter backup.
- After update: recalibrate, re-run arming checks, test failsafes.

## 11. Verification checklist

| Item | Pass criteria |
|------|---------------|
| Heartbeat | GCS sees `HEARTBEAT` from sysid 1 at ≥1 Hz |
| Telemetry | Attitude/position/vfr update at configured rates |
| Command | `COMMAND_ACK` on mode change / arm |
| Failsafe GCS | Stop companion MAVLink → RTL within `FS_GCS_TIMEOUT` |
| Failsafe battery | Simulated low battery → RTL/Land |
| Geofence | Breach simulation → `FENCE_ACTION` |
| Offboard loss (PX4) | Kill setpoints → `COM_OBL_ACT` |

Continue to **[05 — Teleoperation](05-teleoperation.md)**.
