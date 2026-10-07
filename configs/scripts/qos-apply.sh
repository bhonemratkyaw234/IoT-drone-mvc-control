#!/usr/bin/env bash
# qos-apply.sh — UACOM egress QoS over wg0: prioritize MAVLink C2 over video.
# Apply: sudo /usr/local/sbin/qos-apply.sh [iface]   (default wg0)
set -eu

IFACE="${1:-wg0}"
# Link budget passed by video-tx/wan-failover; default conservative.
VIDEO_BPS="${VIDEO_BPS:-4000000}"
TOTAL_BPS="${TOTAL_BPS:-12000000}"

tc qdisc del dev "$IFACE" root 2>/dev/null || true

# Root HTB: 1:1 = total, 1:10 = C2 (priority), 1:20 = video, 1:30 = bulk
tc qdisc add dev "$IFACE" root handle 1: htb default 30
tc class add dev "$IFACE" parent 1: classid 1:1 htb rate "${TOTAL_BPS}bit ceil "${TOTAL_BPS}bit"
tc class add dev "$IFACE" parent 1:1 classid 1:10 htb rate 512kbit ceil "$TOTAL_BPS" prio 0
tc class add dev "$IFACE" parent 1:1 classid 1:20 htb rate "$VIDEO_BPS"bit ceil "$VIDEO_BPS"bit prio 1
tc class add dev "$IFACE" parent 1:1 classid 1:30 htb rate 1mbit ceil 2mbit prio 2

# fq_codel on the interactive classes to keep latency low
tc qdisc add dev "$IFACE" parent 1:10 handle 110: fq_codel
tc qdisc add dev "$IFACE" parent 1:20 handle 120: fq_codel
tc qdisc add dev "$IFACE" parent 1:30 handle 130: fq_codel

# Classify by DSCP (EF=46 -> 1:10, AF21=18 -> 1:20)
tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 \
  match ip tos 0xb8 0xfc flowid 1:10
tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 \
  match ip tos 0x48 0xfc flowid 1:20

echo "$(date -Is) qos applied on $IFACE total=${TOTAL_BPS} video=${VIDEO_BPS}"
