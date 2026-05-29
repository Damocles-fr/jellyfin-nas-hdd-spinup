# Jellyfin NAS HDD Spin-Up at Homepage

Spin up your **NAS hard drives** automatically **right after a remote client reaches Jellyfin's home screen** so the first **Play** is fast.

This tiny watcher tails Jellyfin logs for `WebSocketManager: WS "IP" request` to spin-up HDDs
- Triggers **SCSI START UNIT** (`sg_start --start`) on the **member disks of your data RAID**
- **No filesystem writes** and **no block reads** - reduces the risk of "aborted command / read-only remounts".
- **bypasses SSD/RAM cache** (which would otherwise satisfy file reads without spinning the disks).
- Built-in **cooldown** (default 150s).
- **Boot wait** (default 300s): the watcher self-delays after NAS startup to let QNAP services settle.
- **Not triggered on the login page** - it fires right after the WebSocket is established (typically on the **home** page).
- **LAN optional** - by default only WAN clients trigger; LAN can be enabled.
- Auto-detecting the largest data md. Support specific md array to wake instead (others HDDs group)

---

## Supported / Tested

- **Tested:** QNAP **HS-264**, QTS 5.x, Jellyfin **.qpkg**, SSH as the real **admin** (PuTTY).
- **Storage:** QNAP **TR-004** enclosure.
- **Should also work** on similar NAS models/firmware and docker Jellyfin.
- Requires `sg_start` (from `sg3_utils`). Most QTS builds ship it; if not, install or copy `sg_start` accordingly.

> The watcher performs **no writes** and **no raw reads** on your data volume. It only issues **START UNIT** to the member disks. This is intentionally conservative to avoid the EXT4 read-only remounts seen with naive "dd" wake techniques.

---

## Configuration

Edit the header of `bin/spinup_ws_login.sh` **before** running `install.sh` (or re-install after changes):

- `LOG_DIR` - Jellyfin logs folder. e.g. `/share/CACHEDEV1_DATA/.qpkg/jellyfin/logs`. **Leave empty (`""`) to auto-detect** 
- `COOLDOWN` - seconds between spin-ups. Default: `150`. Keep to avoid unnecessary work.
- `SLEEP` - main loop tick. Default: `2`
- `BOOT_WAIT` - **minimum uptime** (seconds) before doing anything. Default: `300` (5 minutes)
- `ALLOW_PRIVATE` - `0` = only WAN clients (default), `1` = also trigger for LAN/private IPs
- `TRIGGER_PATTERN` - grep-E pattern for Jellyfin log lines. Default: `WebSocketManager: WS ".*" request`
- `FORCE_MD` - if empty, auto-detecting the largest data md. Set to force specific md array to wake instead (others HDDs group). E.g. `md3 md2` to force both md3 and md2.
- `FALLBACK_MD_READ` - keep `0` (OFF). Tiny md read (4K). Set `1` only if `sg_start` alone does not wake on your box.

### Custom install paths

If you set nothing, the installer auto-detects the apps directory and the watcher auto-detects the Jellyfin logs, so the defaults work on most systems.

Not everyone uses `/share/CACHEDEV1_DATA` or `/share/Public/jellyfin-hdd-spinup`. You can override any path by exporting a variable **before** running the installer (and the same for `uninstall.sh`):

| Variable    | Meaning                              | Default                               |
|-------------|--------------------------------------|---------------------------------------|
| `DEST`      | Where the watcher is installed       | `/etc/config/jellyfin-hdd-spinup`     |
| `QPKG_ROOT` | The `.qpkg` apps directory           | auto-detected data volume             |
| `LOG_DIR`   | Jellyfin logs folder                 | empty -> auto-detected at runtime     |
| `QPKG_CONF` | QTS package registry                 | `/etc/config/qpkg.conf`               |
| `CRONTAB`   | QTS crontab file                     | `/etc/config/crontab`                 |

Example:
```sh
LOG_DIR="/share/MD0_DATA/.qpkg/jellyfin/logs" QPKG_ROOT="/share/MD0_DATA/.qpkg" sh ./install.sh
```
---

## Quick install (QNAP, SSH)

1. Upload/unzip this folder on your NAS (any location works, e.g. under `/share/Public/jellyfin-hdd-spinup`).
2. SSH as **admin** (the REAL `admin` account; even an account with admin rights may not work).
3. Run:
```sh
cd /share/Public/jellyfin-hdd-spinup
sh ./install.sh
```
Verify it is running (expect **two lines**):
```sh
ps | grep '[s]pinup_ws_login.sh'
```
4. Close SSH session, in QTS you will have **"Jellyfin HDD Spinup"** app, stop it then launch it again (important).
5. Let disks spin down, then open Jellyfin from **WAN/4G** - the watcher should pre-wake the HDDs on the home screen.

---

## Uninstall

Stop **"Jellyfin HDD Spinup"** app in QTS, then :

```sh
cd /share/Public/jellyfin-hdd-spinup
sh ./uninstall.sh
```
Removes the watcher, the cron guard, the QPKG stub (App Center item), and deletes `/etc/config/jellyfin-hdd-spinup/` and `<apps-dir>/.qpkg/JellyfinHDDSpinup/`.
On some systems **"Jellyfin HDD Spinup"** in QTS App Center may still appear, just click remove.

> If you installed with custom paths, pass the same variables to the uninstaller, e.g.
> `QPKG_ROOT="/share/MD0_DATA/.qpkg" sh ./uninstall.sh`

---

## Verifying & Testing tools

### 1) Detect triggers (no spin-up)
```sh
cd /share/Public/jellyfin-hdd-spinup
sh tools/test_detect.sh
```
Expected output on WAN access:
```
DETECTED WAN WebSocket 'request' from x.x.x.x @ Thu Sep 25 xx:xx:xx CEST 2025
```

### 2) Manual spin-up (same actions as the watcher)
```sh
cd /share/Public/jellyfin-hdd-spinup
sh tools/test_spinup_manual.sh
```
This **only** sends SCSI START UNIT to the detected member disks. **It does not read** from md or files.
To target specific arrays, set `FORCE_MD` at the top of the script (e.g. `FORCE_MD="md3 md2"`).

---

## How it starts on boot

The installer drops a tiny **QPKG-style service** (wrapper) and a **cron guard**:

- QPKG entry in `/etc/config/qpkg.conf`:
  - Section: `[JellyfinHDDSpinup]`
  - Shell: `<apps-dir>/.qpkg/JellyfinHDDSpinup/JellyfinHDDSpinup.sh`
  - Status=complete, Enable=TRUE, Install_Path set accordingly.
- A **cron guard** that, every 2 minutes, starts the service **only after uptime >= 300s** and **only if** the watcher is not already running. If you disable the app in App Center (Enable=FALSE), the guard leaves it stopped.

## Files in this repo

```
bin/spinup_ws_login.sh        # watcher (single-instance, WAN filter, cooldown, boot wait, BusyBox-friendly)
install.sh                    # idempotent installer (/etc/config + QPKG stub + cron guard) and starter
uninstall.sh                  # clean removal (kills watcher, removes cron guard, removes QPKG and files)
tools/test_detect.sh          # detect WAN WebSocket "request" lines (no spin-up)
tools/test_spinup_manual.sh   # manual wake: SCSI START UNIT only (no reads)
README.md                     # this file
```

The installer also creates `cron_guard.sh` inside the install directory (`$DEST`); it is generated on the NAS, not shipped in the repo.

## Transparency

- Since the last version, fixes and improvements were assisted by LLM (Claude Pro) .

## GitHub

https://github.com/Damocles-fr/

