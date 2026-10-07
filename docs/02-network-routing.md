# 02 — Network & Routing

This is the operational core: how three physical links become one resilient C2 network.

## 1. Physical link interfaces (Raspberry Pi 5)

| Link | Interface | Hardware | Notes |
|------|-----------|----------|-------|
| 5 GHz Wi-Fi | `wlan0` | Onboard Wi-Fi (or USB/PCIe 5 GHz radio for range) | Prefer monitor/long-range card or a 5 GHz point-to-point bridge |
| 4G LTE | `wwan0` / `usb0` | USB LTE modem (e.g. Quectel RM5xx / Sierra) via ModemManager | Requires SIM + APN |
| Starlink | `eth1` | Starlink terminal (aircraft or maritime kit) via Ethernet/USB-Eth | Needs Starlink service plane; CGNAT |

> On a Pi 5, `wlan0` is the onboard Wi-Fi. For robust 5 GHz C2 **do not** rely on the
> PCB antenna — use a second 5 GHz radio (USB or M.2/PCIe via the Pi 5 PCIe connector)
> with a proper high-gain antenna, or a dedicated 5 GHz Ethernet bridge.

## 2. IP addressing plan

| Network | Subnet | Purpose |
|---------|--------|---------|
| Management / local | `192.168.50.0/24` | Bench, provisioning |
| Wi-Fi C2 | `10.10.0.0/24` | 5 GHz direct link |
| LTE | carrier | `wwan0` |
| Starlink | carrier | `eth1` |
| **WireGuard overlay** | `10.8.0.0/24` | **All MAVLink/video** |

Overlay (authoritative) addressing:

| Node | wg0 address |
|------|-------------|
| VPS hub (optional) | `10.8.0.1` |
| Aircraft companion | `10.8.0.10` |
| Ground station | `10.8.0.20` |

**All C2 and video traverse `wg0`.** Physical addresses are irrelevant to the
application layer — that is what makes failover seamless.

## 3. Why WireGuard (and not a raw socket)

- Roams across IP changes (Wi-Fi → LTE → Starlink) with no app-visible disruption.
- Both ends behind CGNAT can use a public VPS hub, or a fiber/DSL ground endpoint that
  has a public IP (ground dials out to ground? no — see hub model).
- `AllowedIPs` + `fwmark` gives **policy routing** per link (see §5).
- Cryptographically simple, kernel-fast, and auditable.

### 3.1 Two deployment shapes

**A. Direct (ground has public IP / port-forward):**
```
Aircraft 10.8.0.10 ──out──► ground-public:51820
```

**B. Hub-and-spoke (both behind CGNAT) — recommended for LTE/Starlink:**
```
Aircraft 10.8.0.10 ──┐
                     ├──► VPS 10.8.0.1:51820 ──► relay ──► Ground 10.8.0.20
Ground   10.8.0.20 ──┘
```
The VPS is a lightweight relay (or just routes between spokes). This is the only shape
that works reliably when *both* aircraft and ground are on LTE/Starlink.

## 4. Interface configuration (netplan)

Base config in [`configs/netplan/01-links.yaml`](../configs/netplan/01-links.yaml).
Priority/metrics are intentionally **not** static — the failover daemon owns route
metrics so there is one source of truth.

Key points:
- Wi-Fi and Starlink as static/DHCP DHCP-client interfaces with `use-routes: false`
  where the failover daemon installs default routes.
- LTE managed by NetworkManager + ModemManager (see
  [`configs/networkmanager/`](../configs/networkmanager/)).
- All three get **unique route tables** via policy routing.

## 5. Policy routing (per-link route tables)

Linux routing: one main table, but we create per-WAN tables and select by `fwmark`.
This lets WireGuard pin each *endpoint* to a specific physical link if desired, and
lets the failover daemon flip the default route atomically.

```
# /etc/iproute2/rt_tables
100  wifi
200  lte
300  starlink
```

Rules:
```
ip rule add fwmark 0x64 lookup wifi        # 100
ip rule add fwmark 0xc8 lookup lte         # 200
ip rule add fwmark 0x12c lookup starlink   # 300
```

The active WAN installs the `default` route; on failover, `wan-failover` moves the
default route to the next table and re-marks WireGuard's endpoint socket.

### 5.1 WireGuard endpoint binding (`wg0`)

```ini
[Peer]
Endpoint = vps.example.net:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
```

WireGuard itself follows the system route. To **force** the tunnel over a chosen WAN
when multiple are up, use `fwmark` + a route rule (see
[`configs/wireguard/wg0-aircraft.conf`](../configs/wireguard/wg0-aircraft.conf)):

```
wg set wg0 fwmark 0x64
ip route add 0.0.0.0/0 dev wg0 table 100
```

## 6. Multi-WAN failover daemon

Reference implementation:
[`configs/scripts/wan-failover.sh`](../configs/scripts/wan-failover.sh) and the systemd
unit [`configs/systemd/wan-failover.service`](../configs/systemd/wan-failover.service).

### 6.1 Health scoring algorithm

For each WAN, compute a health score in [0,1] from weighted probes:

| Probe | Weight | Healthy if |
|-------|--------|-----------|
| ICMP to 2 anchors (e.g. `1.1.1.1`, `8.8.8.8`) | 0.30 | reply, RTT < threshold |
| TCP connect to VPS `:51820` | 0.30 | < 2 s |
| DNS resolve | 0.15 | < 1 s |
| WireGuard handshake age | 0.25 | < 180 s |

`score = Σ weight_i · healthy_i`

Failover policy:
- Active link unhealthy for **3 consecutive** rounds (round ≈ 3 s) → demote.
- Promote the highest-scoring healthy standby.
- Hysteresis: standby must beat active by **0.2** to preempt, and link must be stable
  for 2 rounds, to avoid flapping.

### 6.2 Route selection

The daemon sets per-table metrics and installs the default route for the winning table.
Metrics: active `100`, standby `600`. Example:

```
ip route replace default via <gw> dev wlan0 table wifi metric 100
ip route replace default via <gw> dev wwan0 table lte  metric 600
```

### 6.3 Why this survives LTE/Starlink quirks

- LTE CGNAT: we never need inbound; only the WireGuard handshake age matters.
- Starlink: high but variable RTT; thresholds are RTT-relative and latency-tolerant.
- Wi-Fi↔LTE switch: WireGuard roams; MAVLink UDP session continues (router keeps the
  socket; GCS sees a brief gap, not a new session).

## 7. DNS & name resolution

- Overlay DNS via the VPS or a private resolver over `wg0`.
- `systemd-resolved` with per-link DNS; do **not** leak DNS to the wrong link.
- GCS resolves `aircraft.uacom.internal` → `10.8.0.10` locally (hosts or private zone).

## 8. QoS / traffic shaping

**Control must never be starved by video.** Use DSCP + `tc`/cake.

DSCP marks:

| Flow | DSCP | Class |
|------|------|-------|
| MAVLink C2 | `EF` (46) | highest |
| Teleop command | `EF` (46) | highest |
| Telemetry (non-critical) | `AF31` (26) | medium |
| Video | `AF21` (18) | low |
| Bulk/log upload | `CS1` (8) | best-effort |

`tc` on the WireGuard interface (egress) — see
[`configs/scripts/qos-apply.sh`](../configs/scripts/qos-apply.sh). Example: HTB root,
`EF` strict priority, video capped to a link-dependent budget.

### 8.1 Adaptive video

`video-tx` reads the active link (from `wan-failover` state file) and sets bitrate:

| Active link | Video bitrate cap |
|-------------|-------------------|
| Wi-Fi | 8 Mbps |
| LTE | 2 Mbps |
| Starlink | 4 Mbps |
| Degraded | 600 kbps or off |

## 9. NAT, ports, and firewall

Airborne `nftables` default-deny, allow:

```
wg0:  UDP 14550 (MAVLink), UDP 5600 (video), ICMP
physical: only establish WireGuard (UDP 51820 out), DHCP, DNS, ICMP
```

Ground: allow inbound WireGuard on the public IP; relay MAVLink to GCS loopback.

See [`configs/nftables/uacom.nft`](../configs/nftables/uacom.nft).

## 10. MTU & fragmentation

- WireGuard adds ~60–80 bytes overhead. Set `wg0` MTU **1380**.
- LTE/Starlink may path-MTU-black-hole. Use `wg0` MTU 1380 and clamp MSS.
- MAVLink router fragments large messages? No — keep telemetry under MTU; MAVLink2
  messages are small. Video handled at app layer.

## 11. Time sync

- `chrony`/`systemd-timesyncd` over `wg0` to the VPS or GPS/PPS.
- Accurate timestamps matter for log correlation and MAVLink signing nonces.

## 12. Validation matrix

| Scenario | Test | Expected |
|----------|------|----------|
| Wi-Fi → LTE | disable wlan0 | failover < 10 s, MAVLink resumes |
| LTE → Starlink | unplug LTE | failover < 30 s (Starlink tolerant) |
| All down | disable all | FC GCS failsafe → RTL |
| Video saturation | blast 1080p on LTE | C2 latency stays < 150 ms |
| Endpoint change | toggle VPS DNS | tunnel re-handshakes, no restart |

Continue to **[03 — Raspberry Pi 5 Companion Manual](03-pi5-companion-computer.md)**.
