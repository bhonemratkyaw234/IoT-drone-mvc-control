# 09 — Troubleshooting & Maintenance

## 1. Diagnostic quick reference

```bash
# Links
ip -br addr
ip route show table all
cat /run/wan-failover/state.json
wg show
ping -c3 10.8.0.20
mtr -n 10.8.0.20

# MAVLink
sudo systemctl status mavlink-router
journalctl -u mavlink-router -n 100 --no-pager
ls -l /dev/fc

# Video
systemctl status video-tx
gst-launch-1.0 -v udpsrc port=5600 ! fakesink   # local sanity
ffprobe udp://:5600                             # if uav side streams locally

# Power / thermal
vcgencmd measure_temp
vcgencmd get_throttled
vcgencmd measure_volts
df -h
```

## 2. Fault trees

### 2.1 No MAVLink heartbeat at GCS
```
GCS shows no heartbeat
├─ FS/self: is /dev/fc present?           no → UART disabled / cable / udev
├─ mavlink-router active?                  no → ring buffer, start it
├─ FC powered & sending?                   no → FC power / serial baud
├─ verify local UDP 14550                 → mavlink-router-status
├─ overlay up? (wg show, ping)             no → §2.3
└─ firewall blocking 14550?                yes → nftables fix
```

### 2.2 MAVLink present but commands don't work
- Wrong system/component id, or GCS not the source of control.
- FC in a mode that rejects commands (e.g. not GUIDED/OFFBOARD).
- Signing mismatch (signed key differs) → packets dropped.
- Teleop app not sending at required rate (offboard timeout).

### 2.3 WireGuard won't establish
```
wg show (no handshake)
├─ wrong endpoint / DNS              → resolve host from aircraft
├─ public key mismatch              → verify peers
├─ firewall blocking UDP 51820      → nftables / VPS SG
├─ clock skew (WG is clock-tolerant but log times moot) → chrony
├─ CGNAT on both ends               → use VPS hub
└─ MTU/blackhole                    → set wg0 MTU 1380, test ping -M do
```

### 2.4 Failover not switching
- Daemon not running / stale state: `systemctl status wan-failover`.
- Probe anchors unreachable from that WAN (use link-specific probes).
- Metrics manually overridden by a leftover script.
- Hysteresis too aggressive/sticky → tune thresholds, clear flap counter.

### 2.5 Video stutters/black
- Bitrate exceeds link: check active link and `video-tx` bitrate.
- MTU/fragmentation on LTE/Starlink: reduce resolution or use lower overhead.
- Camera not bound to `/dev/video0` or libcamera disabled.
- Firewall blocking UDP 5600.

### 2.6 Thermal throttling
```
vcgencmd get_throttled  → bits set = past/current throttle
```
- Improve airflow, add heatsink/active cooler, reduce video, lower ambient.
- Verify the fan is running; check `companion-health` logs.

### 2.7 Power brownouts
- Voltage drop under load → undersized BEC / long thin wires.
- Add bulk capacitance; separate Pi rail from servos.
- Check `vcgencmd get_throttled` bit 0 (under-voltage).

## 3. Log locations

| Source | Location |
|--------|----------|
| systemd | `journalctl -u <unit>` |
| bananapi/companion health | `/var/log/uacom/health.log` |
| failover | `/run/wan-failover/state.json`, journal |
| MAVLink | `/var/log/uacom/*.tlog` (rotated) |
| GCS | QGC `.tlog` / app logs |

## 4. Maintenance schedule

| Interval | Task |
|----------|------|
| Every flight | Visual inspection, props, connectors, battery voltage |
| Daily | Full preflight, failsafe drill in controlled area (periodic) |
| Weekly | Firmware/param review, log backup, disk check |
| Monthly | Key rotation (or per policy), antenna/SIM/Starlink check, torque check |
| Per 50 h | Motor/prop wear, wiring chafe, thermal paste/fan, recalibrate |
| Annually | Full overhaul, EKF/compass recheck, documentation update |

## 5. Spares & consumables

- Charge cables, props, prop nuts, battery straps.
- Spare Pi 5, SD/NVMe, USB LTE modem, SIMs, antennae, Ethernet cables.
- Fuses, BECs, USB hubs, SIM tools.
- Recovery: keyed WireGuard configs, golden image USB.

## 6. Recovery procedures

- **SD/NVMe corrupt:** reflash golden image, restore params/keys (from secrets store).
- **Modem lost:** swap module, re-check `mmcli -L`.
- **Starlink dish obstructed:** clear view, check sky view app, expect re-boot.
- **Config drift:** diff against repo; redeploy with provisioner.

## 7. Reference commands by subsystem

```bash
# Modem (ModemManager)
mmcli -L
mmcli -m 0 --signal-get
mmcli -m 0 --simple-connect="apn=internet"

# Starlink (dish may expose a local gRPC/status page)
ip addr show eth1
curl -s http://192.168.100.1/ || true   # varies by kit

# Wi-Fi
iw dev wlan0 link
iw dev wlan0 scan | grep -i ssid

# nftables
sudo nft list ruleset
sudo nft monitor

# WireGuard
sudo wg show
sudo wg show wg0 transfer
```

## 8. When to abort and land

- Any repeated failsafe activation.
- Persistent thermal throttling or power brownouts.
- Loss of independent terminate capability.
- EKF/compass/GPS anomalies.
- C2 latency/jitter beyond safe limits for the current mode.

**Safety over mission completion, always.**
