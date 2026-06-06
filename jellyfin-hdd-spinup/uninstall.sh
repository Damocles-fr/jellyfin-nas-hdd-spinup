#!/bin/sh
# uninstall.sh - stop and remove the Jellyfin HDD Spinup watcher and its QPKG entry.
#
# Honors the same path overrides as install.sh (DEST, QPKG_ROOT, QPKG_CONF, CRONTAB).
set -eu

detect_qpkg_root() {
  for d in /share/CACHEDEV*_DATA /share/MD*_DATA /share/ZFS*_DATA /share/DataVol* /share/*; do
    [ -d "$d/.qpkg" ] && { echo "$d/.qpkg"; return 0; }
  done
  return 1
}

DEST="${DEST:-/etc/config/jellyfin-hdd-spinup}"
QPKG_ROOT="${QPKG_ROOT:-$(detect_qpkg_root || true)}"
QPKG_ROOT="${QPKG_ROOT:-/share/CACHEDEV1_DATA/.qpkg}"
QPKG_CONF="${QPKG_CONF:-/etc/config/qpkg.conf}"
CRONTAB="${CRONTAB:-/etc/config/crontab}"

QPKG_DIR="$QPKG_ROOT/JellyfinHDDSpinup"
QPKG_SH="$QPKG_DIR/JellyfinHDDSpinup.sh"

LOCKDIR="/var/run/jellyfin_hdd_spinup.lock"
LAST_SPIN_FILE="/var/run/jellyfin_hdd_spinup.last"

echo "[-] Stopping watcher"
[ -x "$QPKG_SH" ] && "$QPKG_SH" stop >/dev/null 2>&1 || true
# Belt and suspenders: kill any watcher process and any orphan tail directly.
for p in $(ps | grep '[s]pinup_ws_login.sh' | awk '{print $1}'); do kill "$p" 2>/dev/null || true; done
sleep 1
for p in $(ps | grep '[s]pinup_ws_login.sh' | awk '{print $1}'); do kill -9 "$p" 2>/dev/null || true; done
for p in $(ps | grep 'tail -n0 -F' | grep 'jellyfin' | grep -v grep | awk '{print $1}'); do kill "$p" 2>/dev/null || true; done
rm -rf "$LOCKDIR" 2>/dev/null || true
rm -f  "$LAST_SPIN_FILE" /tmp/spinup_ws.* 2>/dev/null || true

echo "[-] Removing cron guard"
grep -v 'JellyfinHDDSpinup\|cron_guard.sh' "$CRONTAB" > "$CRONTAB.new" 2>/dev/null || true
mv "$CRONTAB.new" "$CRONTAB" 2>/dev/null || true
[ -x /etc/init.d/crond.sh ] && /etc/init.d/crond.sh restart || true

echo "[-] Removing QPKG entry from $QPKG_CONF"
tmpconf="$(mktemp)"
awk '
  BEGIN {skip=0}
  /^\[JellyfinHDDSpinup\]/ {skip=1; next}
  /^\[/ {skip=0}
  skip==0 {print}
' "$QPKG_CONF" > "$tmpconf" 2>/dev/null || true
mv "$tmpconf" "$QPKG_CONF" 2>/dev/null || true

echo "[-] Removing installed files"
rm -rf "$QPKG_DIR" 2>/dev/null || true
rm -rf "$DEST" 2>/dev/null || true

echo "[OK] Uninstall complete."
echo "    If 'Jellyfin HDD Spinup' still shows in App Center, click Remove there."
