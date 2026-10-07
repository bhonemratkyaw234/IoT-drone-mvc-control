#!/usr/bin/env bash
# wan-failover.sh — UACOM multi-WAN health scoring and route selection.
#
# Scores each WAN (Wi-Fi, LTE, Starlink) from probes, then installs the default
# route for the best healthy link and writes /run/wan-failover/active-link for
# other services (e.g. adaptive video). WireGuard roams; no tunnel restart needed.
#
# Tunables via environment (see wan-failover.service).
set -u

STATE_DIR="${STATE_DIR:-/run/wan-failover}"
ROUND_SECONDS="${ROUND_SECONDS:-3}"
FAILS_TO_DEMOTE="${FAILS_TO_DEMOTE:-3}"
HYSTERESIS="${HYSTERESIS:-0.2}"

mkdir -p "$STATE_DIR"

WAN_WIFI_IF="${WAN_WIFI_IF:-wlan0}"
WAN_WIFI_TABLE="${WAN_WIFI_TABLE:-wifi}"
WAN_LTE_IF="${WAN_LTE_IF:-wwan0}"
WAN_LTE_TABLE="${WAN_LTE_TABLE:-lte}"
WAN_STAR_IF="${WAN_STAR_IF:-eth1}"
WAN_STAR_TABLE="${WAN_STAR_TABLE:-starlink}"

ANCHOR1="${ANCHOR1:-1.1.1.1}"
ANCHOR2="${ANCHOR2:-8.8.8.8}"
VPS_HOST="${VPS_HOST:-}"
VPS_PORT="${VPS_PORT:-51820}"

log() { echo "$(date -Is) $*" ; }

iface_ip() { ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2; exit}'; }

# Get the gateway even when the interface does not install a default route
# (netplan use-routes: false). Prefer the live route, fall back to DHCP leases.
iface_gw() {
  local iface="$1" gw
  gw="$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{print $3; exit}')"
  if [ -z "$gw" ]; then
    # NetworkManager lease
    for f in /var/lib/NetworkManager/*"$iface"*.lease /var/lib/NetworkManager/*.lease; do
      [ -r "$f" ] || continue
      gw="$(awk -F= '/^routers=/{print $2}' "$f" 2>/dev/null | awk '{print $1; exit}')"
      [ -n "$gw" ] && break
    done
  fi
  if [ -z "$gw" ]; then
    # systemd-networkd lease
    local f="/run/systemd/netif/leases/$(cat /sys/class/net/"$iface"/ifindex 2>/dev/null)"
    [ -r "$f" ] && gw="$(awk -F= '/^ROUTER=/{print $2; exit}' "$f")"
  fi
  echo "$gw"
}

# Probe from a specific interface using a bound source IP (best-effort).
probe_icmp() {
  local iface="$1" ip; ip="$(iface_ip "$iface")"
  [ -z "$ip" ] && { echo 0; return; }
  local src="${ip%/*}"
  if ping -c1 -W1 -I "$src" "$ANCHOR1" >/dev/null 2>&1 \
     || ping -c1 -W1 -I "$src" "$ANCHOR2" >/dev/null 2>&1; then
    echo 1
  else
    echo 0
  fi
}

probe_tcp() {
  [ -z "$VPS_HOST" ] && { echo 1; return; }   # no hub => don't penalize
  local iface="$1" ip; ip="$(iface_ip "$iface")"
  [ -z "$ip" ] && { echo 0; return; }
  local src="${ip%/*}"
  timeout 2 bash -c "exec 3<>/dev/tcp/$VPS_HOST/$VPS_PORT" 2>/dev/null && echo 1 || echo 0
}

probe_dns() {
  local iface="$1" ip; ip="$(iface_ip "$iface")"
  [ -z "$ip" ] && { echo 0; return; }
  local src="${ip%/*}"
  timeout 1 getent -s dns hosts example.com >/dev/null 2>&1 && echo 1 || echo 0
}

wg_handshake_healthy() {
  local age
  age="$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
  if [ -z "$age" ] || [ "$age" -eq 0 ]; then echo 0; return; fi
  local now; now="$(date +%s)"
  if [ $(( now - age )) -lt 180 ]; then echo 1; else echo 0; fi
}

score_wan() {
  local iface="$1"
  local icmp tcp dns wg
  icmp="$(probe_icmp "$iface")"
  tcp="$(probe_tcp "$iface")"
  dns="$(probe_dns "$iface")"
  wg="$(wg_handshake_healthy)"
  # weights: icmp .30 tcp .30 dns .15 wg .25
  awk -v a="$icmp" -v b="$tcp" -v c="$dns" -v d="$wg" \
      'BEGIN{printf "%.2f", a*0.30 + b*0.30 + c*0.15 + d*0.25}'
}

set_default_route() {
  local iface="$1" table="$2" metric="$3" gw
  gw="$(iface_gw "$iface")"
  [ -z "$gw" ] && { log "no gateway on $iface"; return 1; }
  ip route replace default via "$gw" dev "$iface" table "$table" metric "$metric"
}

declare -A FAILS=()
ACTIVE=""

log "wan-failover starting (round=${ROUND_SECONDS}s)"

while true; do
  declare -A SCORE
  for entry in "wifi:$WAN_WIFI_IF" "lte:$WAN_LTE_IF" "starlink:$WAN_STAR_IF"; do
    name="${entry%%:*}"; iface="${entry#*:}"
    SCORE[$name]="$(score_wan "$iface")"
  done

  # Pick best healthy score
  best=""; best_score=0
  for name in wifi lte starlink; do
    s="${SCORE[$name]}"
    awk -v a="$s" -v b="$best_score" 'BEGIN{exit !(a>b)}' && { best="$name"; best_score="$s"; }
  done

  # Hysteresis: only preempt active if best beats it by HYSTERESIS
  if [ -n "$ACTIVE" ] && [ "$best" != "$ACTIVE" ]; then
    as="${SCORE[$ACTIVE]:-0}"
    keep=$(awk -v a="$best_score" -v b="$as" -v h="$HYSTERESIS" 'BEGIN{print (a-b>h)?0:1}')
    [ "$keep" = "1" ] && best="$ACTIVE"
  fi

  # Demote after consecutive failures
  if [ -n "$ACTIVE" ]; then
    if awk -v s="${SCORE[$ACTIVE]:-0}" 'BEGIN{exit !(s<0.4)}'; then
      FAILS[$ACTIVE]=$(( ${FAILS[$ACTIVE]:-0} + 1 ))
    else
      FAILS[$ACTIVE]=0
    fi
    if [ "${FAILS[$ACTIVE]}" -ge "$FAILS_TO_DEMOTE" ]; then
      log "demoting $ACTIVE after ${FAILS[$ACTIVE]} failures"
      ACTIVE=""
    fi
  fi

  [ -z "$best" ] && best="${ACTIVE:-}"

  case "$best" in
    wifi)     set_default_route "$WAN_WIFI_IF" "$WAN_WIFI_TABLE" 100 ;;
    lte)      set_default_route "$WAN_LTE_IF"  "$WAN_LTE_TABLE"  200 ;;
    starlink) set_default_route "$WAN_STAR_IF" "$WAN_STAR_TABLE" 300 ;;
  esac

  if [ -n "$best" ]; then ACTIVE="$best"; fi

  # Persist state for video-tx and observers
  {
    printf '{\n'
    printf '  "active": "%s",\n' "${ACTIVE:-none}"
    printf '  "scores": {"wifi": %s, "lte": %s, "starlink": %s},\n' \
      "${SCORE[wifi]:-0}" "${SCORE[lte]:-0}" "${SCORE[starlink]:-0}"
    printf '  "ts": "%s"\n' "$(date -Is)"
    printf '}\n'
  } > "$STATE_DIR/state.json"
  echo -n "${ACTIVE:-none}" > "$STATE_DIR/active-link"

  log "active=${ACTIVE:-none} wifi=${SCORE[wifi]:-0} lte=${SCORE[lte]:-0} star=${SCORE[starlink]:-0}"
  sleep "$ROUND_SECONDS"
done
