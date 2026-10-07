# 07 — Security Hardening

A transmitter-less aircraft is a **networked node**. Treat C2 as a security-critical
system.

## 1. Threat model (summary)

| Threat | Vector | Mitigation |
|--------|--------|-----------|
| Eavesdropping | Open Wi-Fi/radio | WireGuard encryption |
| Command injection | Spoofed MAVLink | MAVLink2 signing |
| Hijack / takeover | Weak SSH/RDP | Keys only, firewall |
| Data theft | SD/NVMe at rest | Disk encryption |
| Supply chain | Images/packages | Signed images, pinned versions |
| DoS/jamming | RF/network flood | Failover, FC failsafe |
| Ground compromise | Laptop malware | Least privilege, separate segment |

## 2. WireGuard (transport security)

- **Mandatory** for all C2 and video over any untrusted link.
- Use **unique keypairs per aircraft**; never share keys.
- Rotate keys on maintenance cycles and after any suspected compromise.
- Restrict `AllowedIPs` to exactly the overlay subnet(s) needed.
- `PersistentKeepalive = 25` to survive CGNAT.

Configs: [`configs/wireguard/`](../configs/wireguard/).

Generate keys:
```bash
wg genkey | tee privatekey | wg pubkey > publickey
chmod 600 privatekey
```

## 3. MAVLink2 signing

MAVLink2 supports **packet signing** (HMAC-SHA256) to authenticate GCS↔aircraft.

Enable on PX4:
```
MAV_1_MODE = Onboard
# signing is configured per link via the GCS tooling
```
On ArduPilot: set up signing with `mavproxy`/`setup_signing` or via QGC.

Rules:
- **Do not accept unsigned packets** on the C2 link.
- Provision the signing key out of band (never over the air).
- Store the key with strict permissions (`600`, root/uav).
- Rotate on key compromise; re-provision all GCS.

> **Caveat:** signing on some FC links reduces the MAVLink v1 compatibility; ensure the
> GCS speaks MAVLink2.

## 4. SSH / host hardening

`/etc/ssh/sshd_config.d/99-uacom.conf`:
```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers uav
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 30
ClientAliveCountMax 3
```
- Use hardware-backed keys (YubiKey/secure element) for the ground laptop.
- Restrict SSH source to the overlay (`AllowUsers` + nftables on `wg0`).
- Disable unused services (avahi, cups, bluetooth, rpcbind).

## 5. Firewall (nftables)

Default-deny inbound on all physical links; permit only:
- WireGuard `UDP 51820` **outbound** (and inbound on the ground/VPS public IP).
- `wg0`: MAVLink `UDP 14550`/`TCP 5760`, video `UDP 5600`, SSH from GCS.
- ICMP, DHCP, DNS.

Config: [`configs/nftables/uacom.nft`](../configs/nftables/uacom.nft).
```bash
sudo nft -f /etc/nftables/uacom.nft
sudo systemctl enable --now nftables
```

## 6. Disk encryption & boot security

- Enable **LUKS full-disk encryption** at install (or on the NVMe data partition).
- Unlock via key file on a secure element, or TPM where available.
- If full-disk crypto is impractical, at minimum encrypt the **key/log** partition.
- Secure boot / signed boot chain where the platform supports it.

## 7. Identity & access

- Unique per-aircraft keys (WireGuard, SSH, signing).
- A simple PKI (offline CA) for certs if using TLS for telemetry export.
- Inventory: which keys belong to which aircraft; rotate on decommission.
- Never commit secrets to version control; use a secrets store.

## 8. Network segmentation

- Keep **C2** on the overlay only.
- Isolate autonomy/ROS traffic from C2 where possible (separate subnets/VRF).
- Separate **management** (SSH/health) from **payload**.
- The GCS laptop should not also be a browsing machine.

## 9. Telemetry & monitoring security

- Health/monitoring endpoint authenticated (token/mTLS) — never plain HTTP.
- Rate-limit and validate inbound health data.
- Log and alert on: failed handshakes, repeated auth failures, unexpected mode changes.

## 10. Supply chain & updates

- Provision from a **golden image**; verify checksums.
- Pin and verify packages; prefer distro-signed repos.
- Test updates on the bench before fleet rollout.
- Maintain a rollback image.

## 11. Incident response

| Event | Immediate action | Follow-up |
|-------|------------------|-----------|
| Suspected key compromise | Rotate WireGuard + signing keys; land | Audit logs, re-image |
| Unauthorized command | Trigger independent terminate | Forensics on GCS |
| Lost/stolen aircraft | Rotate all keys tied to it | Wipe remote if possible |
| GCS malware | Disconnect from overlay | Re-image ground laptop |

Continue to **[08 — Operations Manual](08-operations-manual.md)**.
