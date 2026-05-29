#!/bin/sh
# Jellyfin WAN WebSocket "request" -> NAS HDD spin-up (QNAP/BusyBox friendly)
# - Tails Jellyfin logs for: WebSocketManager: WS "IP" request
# - WAN-only by default (set ALLOW_PRIVATE=1 to also trigger on LAN)
# - Sends SCSI START UNIT (sg_start --start) to member disks of the largest data md array
# - No filesystem writes, no data reads (avoids SSD cache traps and read-only remounts)
# - Built-in cooldown and boot wait
#
# Config
PATH=/bin:/sbin:/usr/bin:/usr/sbin
LOG_DIR="/share/CACHEDEV1_DATA/.qpkg/jellyfin/logs"
COOLDOWN=150            # seconds between spinups
SLEEP=2                 # loop tick
BOOT_WAIT=300           # seconds after boot before acting (5 min)
ALLOW_PRIVATE=0         # 0 = WAN-only, 1 = allow private LAN IPs
TRIGGER_PATTERN='WebSocketManager: WS ".*" request'  # grep -E pattern
FORCE_MD=""             # e.g., md3 to force a specific md; empty = auto-pick largest data md
FALLBACK_MD_READ=0      # 1 enables tiny md read (4K) before sg_start (kept OFF by default)

LOCKDIR="/var/run/jellyfin_hdd_spinup.lock"
TAILPID=""
last_spin=0

is_private_ip() {
  case "$1" in
    10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null; }

pick_data_md() {
  if [ -n "$FORCE_MD" ] && [ -b "/dev/$FORCE_MD" ]; then
    echo "$FORCE_MD"; return
  fi
  awk '
    BEGIN{md=""}
    /^md[0-9]+ :/ {m=$1; next}
    /blocks/ && m!=""{print m,$1; m=""}
  ' /proc/mdstat 2>/dev/null \
  | grep -Ev '^(md9|md13|md321) ' \
  | sort -k2,2n | tail -1 | awk '{print $1}'
}

md_bases() {
  MD="$1"
  [ -z "$MD" ] && return 0
  line="$(awk -v M="$MD" '$1==M{print;exit}' /proc/mdstat 2>/dev/null)"
  [ -z "$line" ] && return 0
  BASES=""
  for part in $(echo "$line" | grep -Eo '([shv]d[a-z]+[0-9]+)'); do
    b="/dev/$(echo "$part" | sed 's/[0-9]\+$//')"
    echo "$BASES" | grep -qw "$b" || BASES="$BASES $b"
  done
  echo "$BASES"
}

spin_once() {
  # optional tiny md read (default OFF for safety)
  MD="$(pick_data_md)"
  if [ "$FALLBACK_MD_READ" = "1" ] && [ -b "/dev/$MD" ]; then
    dd if="/dev/$MD" of=/dev/null bs=4K count=1 2>/dev/null
  fi

  # sg_start to all base disks
  if command -v sg_start >/dev/null 2>&1; then
    for d in $(md_bases "$MD"); do
      [ -b "$d" ] || continue
      sg_start --start "$d" >/dev/null 2>&1 || true
    done
  fi
}

latest_log() { ls -t "$LOG_DIR"/log_*.log 2>/dev/null | head -n1; }

start_tailproc() {
  [ -n "$TAILPID" ] && kill "$TAILPID" 2>/dev/null
  tail -n 0 -f "$CURRENT_FILE" 2>/dev/null | while IFS= read -r line; do
    echo "$line" | grep -E -q "$TRIGGER_PATTERN" || continue

    # extract first IPv4 on the line
    ip="$(echo "$line" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
    [ -n "$ip" ] || continue

    if [ "$ALLOW_PRIVATE" -eq 0 ] && is_private_ip "$ip"; then
      continue
    fi

    # boot wait guard
    up="$(uptime_s)"; [ -z "$up" ] && up=0
    [ "$up" -ge "$BOOT_WAIT" ] || continue

    now=$(date +%s)
    elapsed=$((now - last_spin))
    if [ "$elapsed" -ge "$COOLDOWN" ]; then
      spin_once
      last_spin=$now
    fi
  done &
  TAILPID=$!
}

cleanup() {
  [ -n "$TAILPID" ] && kill "$TAILPID" 2>/dev/null
  rm -rf "$LOCKDIR" 2>/dev/null
  exit 0
}

# single instance
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap cleanup INT TERM EXIT

# wait for a log file
CURRENT_FILE=""
while :; do
  LATEST="$(latest_log)"
  if [ -n "$LATEST" ] && [ "$LATEST" != "$CURRENT_FILE" ]; then
    CURRENT_FILE="$LATEST"
    start_tailproc
  fi
  sleep "$SLEEP"
done
