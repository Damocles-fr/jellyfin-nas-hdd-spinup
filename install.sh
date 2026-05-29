#!/bin/sh
# install.sh — install Jellyfin HDD Spinup watcher (QNAP-friendly)
set -eu

DEST="/etc/config/jellyfin-hdd-spinup"
QPKG_DIR="/share/CACHEDEV1_DATA/.qpkg/JellyfinHDDSpinup"
QPKG_SH="$QPKG_DIR/JellyfinHDDSpinup.sh"
QPKG_CONF="/etc/config/qpkg.conf"

echo "[+] Installing to: $DEST"
mkdir -p "$DEST"
cp -f "bin/spinup_ws_login.sh" "$DEST/spinup_ws_login.sh"
chmod +x "$DEST/spinup_ws_login.sh"

echo "[+] Creating QPKG shell: $QPKG_SH"
mkdir -p "$QPKG_DIR"
cat > "$QPKG_SH" << 'EOF'
#!/bin/sh
# JellyfinHDDSpinup.sh — tiny QPKG-style wrapper to start/stop the watcher
APP_NAME="JellyfinHDDSpinup"
WATCHER="/etc/config/jellyfin-hdd-spinup/spinup_ws_login.sh"
LOCK="/var/run/jellyfin_hdd_spinup.lock"

start() { 
  # avoid races; if already running, exit 0
  ps | grep -q '[s]pinup_ws_login.sh' && echo "$APP_NAME already running" && exit 0
  /bin/sh -c "$WATCHER >/dev/null 2>&1 &"
  echo "$APP_NAME started"
  exit 0
}
stop() {
  PIDS="$(ps | awk '/[s]pinup_ws_login\.sh/ {print $1}')"
  [ -n "$PIDS" ] && kill -9 $PIDS 2>/dev/null || true
  rm -rf "$LOCK" /tmp/spinup_ws.* 2>/dev/null
  echo "$APP_NAME stopped"
  exit 0
}
restart(){ stop; sleep 1; start; }
status(){ ps | grep '[s]pinup_ws_login.sh' >/dev/null && echo "running" || echo "stopped"; exit 0; }

case "${1:-start}" in
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) status ;;
  *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
chmod +x "$QPKG_SH"

echo "[+] Registering QPKG in $QPKG_CONF"
# Remove existing block if present, then append a clean one
tmpconf="$(mktemp)"
awk '
  BEGIN {skip=0}
  /^\[JellyfinHDDSpinup\]/ {skip=1; next}
  /^\[/ {skip=0}
  skip==0 {print}
' "$QPKG_CONF" > "$tmpconf" 2>/dev/null || true
mv "$tmpconf" "$QPKG_CONF"

cat >> "$QPKG_CONF" << 'EOF'
[JellyfinHDDSpinup]
Name = JellyfinHDDSpinup
Display_Name = Jellyfin HDD Spinup
Version = 1.0.3
Build = 20251002
Author = Community
QPKG_File = jellyfin-hdd-spinup.qpkg
Date = 2025-10-02
Shell = /share/CACHEDEV1_DATA/.qpkg/JellyfinHDDSpinup/JellyfinHDDSpinup.sh
Install_Path = /share/CACHEDEV1_DATA/.qpkg/JellyfinHDDSpinup
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

echo "[+] Adding cron guard (every 2 minutes, waits 5 min uptime)"
guard='*/2 * * * * /bin/sh -c '\''[ $(cut -d. -f1 /proc/uptime) -ge 300 ] || exit 0; ps | grep -q '\''\''[s]pinup_ws_login.sh'\''\'' || "/share/CACHEDEV1_DATA/.qpkg/JellyfinHDDSpinup/JellyfinHDDSpinup.sh" start >/dev/null 2>&1'\'''
grep -v 'JellyfinHDDSpinup' /etc/config/crontab > /etc/config/crontab.new 2>/dev/null || true
echo "$guard" >> /etc/config/crontab.new
mv /etc/config/crontab.new /etc/config/crontab
/etc/init.d/crond.sh restart

echo "[+] Starting watcher via QPKG wrapper"
"/share/CACHEDEV1_DATA/.qpkg/JellyfinHDDSpinup/JellyfinHDDSpinup.sh" start >/dev/null 2>&1 || true

echo "[OK] Install complete."
