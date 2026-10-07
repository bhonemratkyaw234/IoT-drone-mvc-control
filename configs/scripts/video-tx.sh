#!/usr/bin/env bash
# video-tx.sh — UACOM camera -> GCS H.264/RTP over the wg0 overlay.
# Adapts bitrate to the active WAN reported by wan-failover.
set -u

GCS_HOST="${GCS_HOST:-10.8.0.20}"
GCS_PORT="${GCS_PORT:-5600}"
STATE_FILE="${STATE_FILE:-/run/wan-failover/active-link}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"

bitrate_for_link() {
  local link="none"
  [ -r "$STATE_FILE" ] && link="$(cat "$STATE_FILE")"
  case "$link" in
    wifi)     echo 8000000 ;;
    starlink) echo 4000000 ;;
    lte)      echo 1500000 ;;
    *)        echo 600000 ;;
  esac
}

BITRATE="$(bitrate_for_link)"
echo "$(date -Is) video-tx start link-bitrate=${BITRATE}"

# libcamera-vid (Raspberry Pi OS / Ubuntu with libcamera)
exec libcamera-vid -n -t 0 --inline --codec h264 \
  --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
  --bitrate "$BITRATE" -o - \
  | gst-launch-1.0 -e fdsrc ! \
      h264parse config-interval=1 ! \
      rtph264pay pt=96 ! \
      udpsink host="$GCS_HOST" port="$GCS_PORT" sync=false
