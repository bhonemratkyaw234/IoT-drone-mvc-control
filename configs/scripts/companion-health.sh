#!/usr/bin/env bash
# companion-health.sh — UACOM thermal / power / disk supervisor.
set -u

POLL_SECONDS="${POLL_SECONDS:-5}"
TEMP_WARN="${TEMP_WARN:-75}"
TEMP_CRIT="${TEMP_CRIT:-80}"
TEMP_SHUTDOWN="${TEMP_SHUTDOWN:-85}"
V_WARN="${V_WARN:-4.75}"
V_SHUTDOWN="${V_SHUTDOWN:-4.65}"
DISK_WARN="${DISK_WARN:-85}"

LOG_DIR="${LOG_DIR:-/var/log/uacom}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/health.log"

log() { echo "$(date -Is) $*" | tee -a "$LOG"; }

read_temp_c() {
  if command -v vcgencmd >/dev/null 2>&1; then
    vcgencmd measure_temp 2>/dev/null | sed -n "s/temp=\([0-9.]*\).*/\1/p"
  else
    awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null
  fi
}

read_volts() {
  if command -v vcgencmd >/dev/null 2>&1; then
    vcgencmd measure_volts core 2>/dev/null | sed -n 's/volt=\([0-9.]*\)V.*/\1/p'
  fi
}

log "companion-health starting"

was_shutdown=0
while true; do
  temp="$(read_temp_c)"; temp="${temp:-0}"
  volts="$(read_volts)"; volts="${volts:-0}"
  disk="$(df --output=pcent / | tail -1 | tr -dc '0-9')"; disk="${disk:-0}"
  throttled="$(vcgencmd get_throttled 2>/dev/null || echo unknown)"

  # Thermal
  if awk -v t="$temp" -v c="$TEMP_SHUTDOWN" 'BEGIN{exit !(t>=c)}'; then
    log "CRIT thermal ${temp}C >= ${TEMP_SHUTDOWN}C : graceful shutdown in 10s"
    sleep 10; systemctl poweroff
  elif awk -v t="$temp" -v c="$TEMP_CRIT" 'BEGIN{exit !(t>=c)}'; then
    log "CRIT thermal ${temp}C : disabling video"
    systemctl stop video-tx 2>/dev/null || true
  elif awk -v t="$temp" -v c="$TEMP_WARN" 'BEGIN{exit !(t>=c)}'; then
    log "WARN thermal ${temp}C : reducing video"
    systemctl restart video-tx 2>/dev/null || true
  fi

  # Power
  if [ "$volts" != "0" ] && awk -v v="$volts" -v c="$V_SHUTDOWN" 'BEGIN{exit !(v<c)}'; then
    if [ "$was_shutdown" -eq 0 ]; then
      log "CRIT voltage ${volts}V : shutdown in 10s"; was_shutdown=1; sleep 10; systemctl poweroff
    fi
  elif [ "$volts" != "0" ] && awk -v v="$volts" -v c="$V_WARN" 'BEGIN{exit !(v<c)}'; then
    log "WARN voltage ${volts}V below ${V_WARN}V"
  fi

  # Disk
  if [ "$disk" -ge "$DISK_WARN" ]; then
    log "WARN disk ${disk}% full : rotating logs"
    journalctl --vacuum-size=200M >/dev/null 2>&1 || true
  fi

  # Throttle flags
  case "$throttled" in
    *0x0|*unknown) : ;;
    *) log "WARN vcgencmd throttle flags: $throttled" ;;
  esac

  sleep "$POLL_SECONDS"
done
