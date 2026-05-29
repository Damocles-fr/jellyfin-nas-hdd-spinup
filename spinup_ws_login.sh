#!/bin/sh
# Jellyfin WAN WebSocket "request" -> NAS HDD spin-up (QNAP/BusyBox friendly)
# - Tails Jellyfin logs for: WebSocketManager: WS "IP" request
# - WAN-only by default (set ALLOW_PRIVATE=1 to also trigger on LAN)
# - Sends SCSI START UNIT (sg_start --start) to member disks of the specified md arrays
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

# List what md to spin-up
# E.g. :
#   FORCE_MD="md3"            → only one array
#   FORCE_MD="md3 md4"        → two array
#   FORCE_MD=""               → auto-detect the biggest array (biggest HDDs group)
FORCE_MD=""

FALLBACK_MD_READ=0      # 1 enables tiny md read (4K) before sg_start (kept OFF by default)

LOCKDIR="/var/run/jellyfin_hdd_spinup.lock"
LAST_SPIN_FILE="/var/run/jellyfin_hdd_spinup.last"
TAILPID=""

is_private_ip() {
  case "$1" in
    10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null; }

# biggest md data (no system md)
pick_data_md() {
  awk '
    BEGIN{md=""}
    /^md[0-9]+ :/ {m=$1; next}
    /blocks/ && m!=""{print m,$1; m=""}
  ' /proc/mdstat 2>/dev/null \
  | grep -Ev '^(md9|md13|md321) ' \
  | sort -k2,2n | tail -1 | awk '{print $1}'
}

# HDDs md (e.g.: md3 -> /dev/sda /dev/sdb ...)
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
  # Spin-up list
  if [ -n "$FORCE_MD" ]; then
    MD_LIST="$FORCE_MD"           # manual e.g. : "md3 md256"
  else
    MD_LIST="$(pick_data_md)"     # auto: biggest md
  fi

  for MD in $MD_LIST; do
    # md exist
    [ -b "/dev/$MD" ] || { echo "WARNING: /dev/$MD not found, skipping" >&2; continue; }

    # Fallback read data (default OFF)
    if [ "$FALLBACK_MD_READ" = "1" ]; then
      dd if="/dev/$MD" of=/dev/null bs=4K count=1 2>/dev/null
    fi

    # sg_start on each HDDs
    if command -v sg_start >/dev/null 2>&1; then
      for d in $(md_bases "$MD"); do
        [ -b "$d" ] || continue
        sg_start --start "$d" >/dev/null 2>&1 || true
      done
    fi
  done
}

latest_log() { ls -t "$LOG_DIR"/log_*.log 2>/dev/null | head -n1; }

start_tailproc() {

  # Kill previous tail process cleanly
  if [ -n "$TAILPID" ]; then
    kill "$TAILPID" 2>/dev/null
    wait "$TAILPID" 2>/dev/null
  fi

  # Emergency cleanup: kill orphan tails still watching old Jellyfin logs
  ps | grep 'tail -n0 -F' | grep '/.qpkg/jellyfin/logs/log_' | grep -v grep | awk '{print $1}' | while read -r p; do
    [ "$p" != "$$" ] && kill "$p" 2>/dev/null
  done

  tail -n0 -F "$CURRENT_FILE" 2>/dev/null | while IFS= read -r line; do

    echo "$line" | grep -qE "$TRIGGER_PATTERN" || continue

    ip="$(echo "$line" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
    [ -n "$ip" ] || continue

    if [ "$ALLOW_PRIVATE" != "1" ]; then
      is_private_ip "$ip" && continue
    fi

    now="$(date +%s)"
    last_spin="$(cat "$LAST_SPIN_FILE" 2>/dev/null || echo 0)"
    elapsed=$((now - last_spin))

    if [ "$elapsed" -ge "$COOLDOWN" ]; then
      echo "$now" > "$LAST_SPIN_FILE"
      spin_once
    fi

  done &

  TAILPID=$!
}

cleanup() {
  [ -n "$TAILPID" ] && kill "$TAILPID" 2>/dev/null
  rm -rf "$LOCKDIR" 2>/dev/null
  rm -f  "$LAST_SPIN_FILE" 2>/dev/null
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
