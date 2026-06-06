#!/bin/sh
# test_detect.sh - show WAN WebSocket "request" detections only (no spin-up).
# Useful to confirm that remote access produces the expected log line.

# Jellyfin log directory. Leave empty to auto-detect, or set it explicitly.
LOG_DIR=""
TRIGGER_PATTERN='WebSocketManager: WS ".*" request'

detect_log_dir() {
  for d in /share/*/.qpkg/jellyfin/logs; do
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}

[ -n "$LOG_DIR" ] || LOG_DIR="$(detect_log_dir)"
[ -n "$LOG_DIR" ] || { echo "Could not find the Jellyfin log directory. Set LOG_DIR at the top of this script."; exit 1; }

LATEST="$(ls -t "$LOG_DIR"/log_*.log 2>/dev/null | head -n1)"
[ -n "$LATEST" ] || { echo "No Jellyfin log files in $LOG_DIR"; exit 1; }

echo "Watching: $LATEST"
echo "Open Jellyfin from a WAN/4G client to see a detection. Press Ctrl-C to stop."

tail -n0 -F "$LATEST" | while IFS= read -r line; do
  echo "$line" | grep -E -q "$TRIGGER_PATTERN" || continue
  for ip in $(echo "$line" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'); do
    case "$ip" in
      10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) ;;
      *) echo "DETECTED WAN WebSocket 'request' from $ip @ $(date)"; break ;;
    esac
  done
done
