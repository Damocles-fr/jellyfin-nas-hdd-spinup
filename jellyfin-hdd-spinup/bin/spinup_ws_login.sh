#!/bin/sh
# Jellyfin WAN WebSocket "request" -> NAS HDD spin-up (QNAP / BusyBox friendly)
#
# What it does:
#   - Tails the current Jellyfin log for lines like: WebSocketManager: WS "IP" request
#   - For public (WAN) client IPs, issues a read-only wake to the data RAID disks
#   - Wake = SCSI START UNIT (sg_start --start) on each member disk of the chosen md array(s)
#   - No filesystem writes and no block reads (avoids SSD-cache traps and read-only remounts)
#   - Built-in cooldown and boot-wait
#
# Lifecycle notes:
#   - Single instance is enforced by a PID-aware lock that auto-recovers from a stale lock
#     left behind by a hard kill or an unclean shutdown (this is why a previous run that was
#     killed with "kill -9" no longer blocks the next start).
#   - On exit the watcher tears down its background tail worker so nothing is left running.

# ---------------------------------------------------------------------------
# Config (safe to edit before install, or re-run install.sh after changing)
# ---------------------------------------------------------------------------
PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Jellyfin log directory.
#   Leave empty ("") to auto-detect (handles NAS that do not use CACHEDEV1_DATA).
#   Or set it explicitly, e.g. LOG_DIR="/share/CACHEDEV1_DATA/.qpkg/jellyfin/logs"
LOG_DIR=""

COOLDOWN=150            # minimum seconds between two spin-ups
SLEEP=2                 # main loop tick (seconds)
BOOT_WAIT=300           # do nothing until the NAS has been up this many seconds (5 min)
ALLOW_PRIVATE=0         # 0 = only WAN/public client IPs trigger, 1 = also LAN/private IPs
TRIGGER_PATTERN='WebSocketManager: WS ".*" request'   # grep -E pattern for the log line

# Which md array(s) to spin up (space separated). Examples:
#   FORCE_MD="md3"          -> only this array
#   FORCE_MD="md3 md2"      -> these two arrays (e.g. main enclosure + expansion enclosure)
#   FORCE_MD=""             -> auto-detect the largest data array (biggest group of HDDs)
FORCE_MD=""

FALLBACK_MD_READ=0      # keep 0 (OFF). Set 1 only if sg_start alone does not wake your disks.

# ---------------------------------------------------------------------------
# Internal paths (do not normally need editing)
# ---------------------------------------------------------------------------
LOCKDIR="/var/run/jellyfin_hdd_spinup.lock"   # atomic single-instance lock (a directory)
PIDFILE="$LOCKDIR/pid"                         # PID of the running watcher (inside the lock)
LAST_SPIN_FILE="/var/run/jellyfin_hdd_spinup.last"   # last spin-up timestamp (cooldown state)

# Source of RAID info. Overridable for testing only; defaults to the real kernel file.
MDSTAT="${MDSTAT:-/proc/mdstat}"

TAILPID=""             # PID of the background tail worker (the log-reading sub-shell)

# ---------------------------------------------------------------------------
# Single-instance lock (atomic + stale-recovering)
#   mkdir is atomic, so it prevents two watchers starting at the same time.
#   If the lock already exists we check whether its owner PID is still alive:
#     - alive  -> a real instance is running, so we exit
#     - dead   -> the lock is stale (hard kill / crash / reboot), so we reclaim it
# ---------------------------------------------------------------------------
acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" > "$PIDFILE" 2>/dev/null
    return 0
  fi
  oldpid="$(cat "$PIDFILE" 2>/dev/null)"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    return 1
  fi
  # Stale lock: remove and try once more.
  rm -rf "$LOCKDIR" 2>/dev/null
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo "$$" > "$PIDFILE" 2>/dev/null
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_private_ip() {
  case "$1" in
    10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null; }

# Auto-detect the Jellyfin log directory across common QNAP volume names.
detect_log_dir() {
  for d in /share/*/.qpkg/jellyfin/logs; do
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}

# Auto-pick the largest data md array (excludes known QNAP system arrays).
pick_data_md() {
  awk '
    BEGIN{md=""}
    /^md[0-9]+ :/ {m=$1; next}
    /blocks/ && m!=""{print m,$1; m=""}
  ' "$MDSTAT" 2>/dev/null \
  | grep -Ev '^(md9|md13|md321) ' \
  | sort -k2,2n | tail -1 | awk '{print $1}'
}

# Return the base block devices of a given md array (e.g. md3 -> /dev/sda /dev/sdb ...).
md_bases() {
  MD="$1"
  [ -z "$MD" ] && return 0
  line="$(awk -v M="$MD" '$1==M{print;exit}' "$MDSTAT" 2>/dev/null)"
  [ -z "$line" ] && return 0
  BASES=""
  for part in $(echo "$line" | grep -Eo '([shv]d[a-z]+[0-9]+)'); do
    b="/dev/$(echo "$part" | sed 's/[0-9]\+$//')"
    echo "$BASES" | grep -qw "$b" || BASES="$BASES $b"
  done
  echo "$BASES"
}

# Send SCSI START UNIT to every member disk of every selected md array.
spin_once() {
  if [ -n "$FORCE_MD" ]; then
    MD_LIST="$FORCE_MD"           # manual list, e.g. "md3 md2"
  else
    MD_LIST="$(pick_data_md)"     # auto: largest data array
  fi

  for MD in $MD_LIST; do
    if [ ! -b "/dev/$MD" ]; then
      echo "WARNING: /dev/$MD not found, skipping" >&2
      continue
    fi

    # Optional tiny read (default OFF) for boxes where sg_start alone is not enough.
    if [ "$FALLBACK_MD_READ" = "1" ]; then
      dd if="/dev/$MD" of=/dev/null bs=4K count=1 2>/dev/null
    fi

    if command -v sg_start >/dev/null 2>&1; then
      for d in $(md_bases "$MD"); do
        [ -b "$d" ] || continue
        sg_start --start "$d" >/dev/null 2>&1 || true
      done
    fi
  done
}

latest_log() { ls -t "$LOG_DIR"/log_*.log 2>/dev/null | head -n1; }

# ---------------------------------------------------------------------------
# Background tail worker
#   The cooldown timestamp is shared through LAST_SPIN_FILE because the pipe
#   runs in a sub-shell that cannot write back to the parent's variables.
# ---------------------------------------------------------------------------
start_tailproc() {
  # Stop the previous worker (if any) before starting a new one.
  if [ -n "$TAILPID" ]; then
    kill "$TAILPID" 2>/dev/null
    wait "$TAILPID" 2>/dev/null
    TAILPID=""
  fi
  # Sweep any orphan tail still following our log directory (e.g. after log rotation).
  for p in $(ps | grep 'tail -n0 -F' | grep "$LOG_DIR" | grep -v grep | awk '{print $1}'); do
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

# ---------------------------------------------------------------------------
# Cleanup on exit: tear down the tail worker so nothing is left running.
#   We kill the worker sub-shell (TAILPID) and also sweep the tail process it
#   spawned (a separate child that would otherwise survive as an orphan).
# ---------------------------------------------------------------------------
cleanup() {
  trap '' INT TERM EXIT          # avoid re-entering cleanup while cleaning up
  [ -n "$TAILPID" ] && kill "$TAILPID" 2>/dev/null
  for p in $(ps | grep 'tail -n0 -F' | grep "$LOG_DIR" | grep -v grep | awk '{print $1}'); do
    [ "$p" != "$$" ] && kill "$p" 2>/dev/null
  done
  rm -rf "$LOCKDIR" 2>/dev/null
  rm -f  "$LAST_SPIN_FILE" 2>/dev/null
  exit 0
}

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
acquire_lock || exit 0
trap cleanup INT TERM EXIT

# Resolve the log directory (auto-detect if not set explicitly).
[ -n "$LOG_DIR" ] || LOG_DIR="$(detect_log_dir)"

# Boot wait: stay idle until the NAS has settled, regardless of who started us.
while :; do
  up="$(uptime_s)"; [ -n "$up" ] || up=0
  [ "$up" -ge "$BOOT_WAIT" ] && break
  sleep "$SLEEP"
done

# Main loop: follow the newest Jellyfin log and (re)start the tail worker on rotation.
CURRENT_FILE=""
while :; do
  # Re-resolve the log dir in case Jellyfin was installed/started after us.
  [ -n "$LOG_DIR" ] || LOG_DIR="$(detect_log_dir)"

  LATEST="$(latest_log)"
  if [ -n "$LATEST" ] && [ "$LATEST" != "$CURRENT_FILE" ]; then
    CURRENT_FILE="$LATEST"
    start_tailproc
  fi
  sleep "$SLEEP"
done
