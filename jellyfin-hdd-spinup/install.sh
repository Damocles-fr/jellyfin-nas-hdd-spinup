#!/bin/sh
# install.sh - install the Jellyfin HDD Spinup watcher on QNAP (QTS 5.x and similar)
#
# It installs three small pieces:
#   1) the watcher  -> $DEST/spinup_ws_login.sh   (on the config partition, persists reboots)
#   2) a QPKG-style wrapper so the app shows up and can be started/stopped from QTS App Center
#   3) a cron guard that (re)starts the watcher after boot, unless the app was disabled in QTS
#
# Configurable paths (override by exporting before running, e.g. LOG_DIR=... sh install.sh):
#   DEST       watcher install dir            default: /etc/config/jellyfin-hdd-spinup
#   QPKG_ROOT  the ".qpkg" apps dir           default: auto-detected data volume
#   LOG_DIR    Jellyfin logs dir              default: empty -> watcher auto-detects at runtime
#   QPKG_CONF  QTS package registry           default: /etc/config/qpkg.conf
#   CRONTAB    QTS crontab file               default: /etc/config/crontab
set -eu

# Resolve our own directory so the installer works from any current directory.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Auto-detect the ".qpkg" apps directory (handles NAS without CACHEDEV1_DATA) ---
detect_qpkg_root() {
  for d in /share/CACHEDEV*_DATA /share/MD*_DATA /share/ZFS*_DATA /share/DataVol* /share/*; do
    [ -d "$d/.qpkg" ] && { echo "$d/.qpkg"; return 0; }
  done
  return 1
}

DEST="${DEST:-/etc/config/jellyfin-hdd-spinup}"
QPKG_ROOT="${QPKG_ROOT:-$(detect_qpkg_root || true)}"
QPKG_ROOT="${QPKG_ROOT:-/share/CACHEDEV1_DATA/.qpkg}"   # last-resort fallback
QPKG_CONF="${QPKG_CONF:-/etc/config/qpkg.conf}"
CRONTAB="${CRONTAB:-/etc/config/crontab}"
LOG_DIR="${LOG_DIR:-}"

QPKG_DIR="$QPKG_ROOT/JellyfinHDDSpinup"
QPKG_SH="$QPKG_DIR/JellyfinHDDSpinup.sh"

APP_DISPLAY="Jellyfin HDD Spinup"
VERSION="1.1.0"
BUILD="20260529"
DATE="2026-05-29"

echo "[+] Apps directory (QPKG_ROOT): $QPKG_ROOT"
echo "[+] Installing watcher to:      $DEST"

# --- 1) Install the watcher --------------------------------------------------
mkdir -p "$DEST"
cp -f "$SELF_DIR/bin/spinup_ws_login.sh" "$DEST/spinup_ws_login.sh"
chmod +x "$DEST/spinup_ws_login.sh"

# Optional: bake an explicit LOG_DIR into the installed watcher header.
# If LOG_DIR is left empty, the watcher auto-detects it at runtime.
if [ -n "$LOG_DIR" ]; then
  echo "[+] Setting LOG_DIR to: $LOG_DIR"
  esc="$(printf '%s' "$LOG_DIR" | sed 's/[&/\]/\\&/g')"
  sed -i "s#^LOG_DIR=.*#LOG_DIR=\"$esc\"#" "$DEST/spinup_ws_login.sh"
fi

# --- 2) Write the QPKG-style wrapper ----------------------------------------
echo "[+] Creating QPKG wrapper: $QPKG_SH"
mkdir -p "$QPKG_DIR"
{
  # Only $DEST is expanded here; runtime variables are kept literal via \$.
  cat <<EOF
#!/bin/sh
# JellyfinHDDSpinup.sh - QPKG-style wrapper to start/stop/status the watcher.
APP_NAME="Jellyfin HDD Spinup"
WATCHER="$DEST/spinup_ws_login.sh"
LOCKDIR="/var/run/jellyfin_hdd_spinup.lock"
PIDFILE="\$LOCKDIR/pid"
LAST_SPIN_FILE="/var/run/jellyfin_hdd_spinup.last"
EOF
  cat <<'EOF'

# True only if a watcher instance is actually alive. PID-aware and PID-reuse
# proof: a stale lock, or a recycled PID now used by another process, is not
# mistaken for a running watcher.
running() {
  [ -f "$PIDFILE" ] || return 1
  p="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  [ -r "/proc/$p/cmdline" ] || return 0
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'spinup_ws_login.sh'
}

start() {
  if running; then
    echo "$APP_NAME already running"
    exit 0
  fi
  # Daemonize: the inner shell backgrounds the watcher and exits immediately, so
  # the watcher is reparented to init and keeps running after this wrapper returns.
  /bin/sh -c "$WATCHER >/dev/null 2>&1 &"
  echo "$APP_NAME started"
  exit 0
}

stop() {
  # 1) Ask the watcher to stop so its own trap tears down the tail worker cleanly.
  if [ -f "$PIDFILE" ]; then
    mpid="$(cat "$PIDFILE" 2>/dev/null)"
    [ -n "$mpid" ] && kill "$mpid" 2>/dev/null
  fi
  # 2) Also signal by name, in case the PID file is missing or stale.
  for p in $(ps | grep '[s]pinup_ws_login.sh' | awk '{print $1}'); do
    kill "$p" 2>/dev/null
  done
  # 3) Give the trap a moment to run.
  sleep 1
  # 4) Force-kill anything that ignored the first signal.
  for p in $(ps | grep '[s]pinup_ws_login.sh' | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null
  done
  # 5) Safety net: sweep any orphan "tail -F" still following the Jellyfin logs.
  for p in $(ps | grep 'tail -n0 -F' | grep 'jellyfin' | grep -v grep | awk '{print $1}'); do
    kill "$p" 2>/dev/null
  done
  # 6) Clean lock and state so the next start is never blocked.
  rm -rf "$LOCKDIR" 2>/dev/null
  rm -f  "$LAST_SPIN_FILE" 2>/dev/null
  echo "$APP_NAME stopped"
  exit 0
}

restart() { stop >/dev/null 2>&1; sleep 1; start; }

status() {
  if running; then echo "running"; else echo "stopped"; fi
  exit 0
}

case "${1:-start}" in
  start)   start ;;
  stop)    stop ;;
  restart) restart ;;
  status)  status ;;
  *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
} > "$QPKG_SH"
chmod +x "$QPKG_SH"

# --- 3) Write the cron guard -------------------------------------------------
echo "[+] Creating cron guard: $DEST/cron_guard.sh"
{
  cat <<EOF
#!/bin/sh
# cron_guard.sh - keep the watcher running after boot.
# Started every 2 minutes by cron. It does nothing until the NAS has settled,
# respects an App Center "disable" (Enable=FALSE), and never starts a duplicate.
WRAPPER="$QPKG_SH"
QPKG_CONF="$QPKG_CONF"
EOF
  cat <<'EOF'
LOCKDIR="/var/run/jellyfin_hdd_spinup.lock"
PIDFILE="$LOCKDIR/pid"
BOOT_WAIT=300

up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"; [ -n "$up" ] || up=0
[ "$up" -ge "$BOOT_WAIT" ] || exit 0

# If QTS knows this app and it has been disabled in App Center, stay stopped.
if command -v getcfg >/dev/null 2>&1; then
  en="$(getcfg JellyfinHDDSpinup Enable -d TRUE -f "$QPKG_CONF" 2>/dev/null)"
  [ "$en" = "TRUE" ] || exit 0
fi

# Already running? PID-aware and PID-reuse proof: only skip the start if the
# stored PID is alive AND is really our watcher (a recycled PID used by some
# other process must not be mistaken for a running watcher).
if [ -f "$PIDFILE" ]; then
  p="$(cat "$PIDFILE" 2>/dev/null)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    if [ ! -r "/proc/$p/cmdline" ] || tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'spinup_ws_login.sh'; then
      exit 0
    fi
  fi
fi

"$WRAPPER" start >/dev/null 2>&1
EOF
} > "$DEST/cron_guard.sh"
chmod +x "$DEST/cron_guard.sh"

# --- Register the QPKG entry so it appears in App Center ---------------------
echo "[+] Registering QPKG in: $QPKG_CONF"
touch "$QPKG_CONF"
tmpconf="$(mktemp)"
awk '
  BEGIN {skip=0}
  /^\[JellyfinHDDSpinup\]/ {skip=1; next}
  /^\[/ {skip=0}
  skip==0 {print}
' "$QPKG_CONF" > "$tmpconf" 2>/dev/null || true
mv "$tmpconf" "$QPKG_CONF"

cat >> "$QPKG_CONF" <<EOF
[JellyfinHDDSpinup]
Name = JellyfinHDDSpinup
Display_Name = $APP_DISPLAY
Version = $VERSION
Build = $BUILD
Author = Community
QPKG_File = jellyfin-hdd-spinup.qpkg
Date = $DATE
Shell = $QPKG_SH
Install_Path = $QPKG_DIR
Enable = TRUE
Status = complete
Visible = 1
Desktop = 0
Web_Port = -1
Web_SSL_Port = -1
WebUI =
Opt_Xml = 0
FW_Ver_Min = 4.3.3
EOF

# --- Install the cron guard line --------------------------------------------
echo "[+] Adding cron guard (every 2 minutes, waits 5 min uptime)"
touch "$CRONTAB"
grep -v 'JellyfinHDDSpinup\|cron_guard.sh' "$CRONTAB" > "$CRONTAB.new" 2>/dev/null || true
echo "*/2 * * * * $DEST/cron_guard.sh >/dev/null 2>&1" >> "$CRONTAB.new"
mv "$CRONTAB.new" "$CRONTAB"
[ -x /etc/init.d/crond.sh ] && /etc/init.d/crond.sh restart || true

# --- (Re)start cleanly -------------------------------------------------------
echo "[+] (Re)starting watcher via the wrapper"
"$QPKG_SH" stop  >/dev/null 2>&1 || true
"$QPKG_SH" start >/dev/null 2>&1 || true

echo "[OK] Install complete. Check with:  ps | grep '[s]pinup_ws_login.sh'"
