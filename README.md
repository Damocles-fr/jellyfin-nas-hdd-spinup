# Jellyfin NAS HDD Spin‑Up at Homepage

Spin up your **NAS hard drives** automatically **right after a remote client reaches Jellyfin’s home screen** so the first **Play** is fast.

This tiny watcher tails Jellyfin logs for `WebSocketManager: WS "IP" request` and, for **public (WAN) IPs**, immediately issues a **read‑only wake**:
- Triggers **SCSI START UNIT** (`sg_start --start`) on the **member disks of your data RAID** (auto‑detected from `/proc/mdstat`).
- **No filesystem writes** and **no block reads** — avoids SSD‑cache traps and reduces the risk of “aborted command / read‑only remounts.”
- Built‑in **cooldown** (default 150s) to prevent repeated wake‑ups.
- **Boot wait** (default 300s ≈ 5 minutes): the watcher self‑delays after NAS startup to let QNAP services settle.

This **bypasses SSD/RAM cache** (which would otherwise satisfy file reads without spinning the disks) so the HDDs are already awake when you hit **Play**.

> **Not triggered on the login page** — it fires right after the WebSocket is established (typically on the **home** page).  
> **LAN optional** — by default only WAN clients trigger; LAN can be enabled.

---

## Supported / Tested

- **Tested:** QNAP **HS‑264**, QTS 5.x, Jellyfin **.qpkg** (logs under `/share/CACHEDEV1_DATA/.qpkg/jellyfin/logs`), SSH as **admin** (PuTTY).
- **Storage:** QNAP **TR‑004** enclosure (member drives seen as `/dev/sdX`, data RAID visible in `/proc/mdstat`).
- **Should also work** on similar NAS models/firmware with the same log layout and md RAID devices.
- Requires `sg_start` (from `sg3_utils`). Most QTS builds ship it; if not, install or copy `sg_start` accordingly.

> The watcher performs **no writes** and **no raw reads** on your data volume. It only issues **START UNIT** to the member disks. This is intentionally conservative to avoid the EXT4 read‑only remounts seen with naive “dd” wake techniques.

---

## How it starts on boot

The installer drops a tiny **QPKG-style service** (wrapper) and a **cron guard**:

- QPKG entry in `/etc/config/qpkg.conf`:
  - Section: `[JellyfinHDDSpinup]`
  - Shell: `/share/CACHEDEV1_DATA/.qpkg/JellyfinHDDSpinup/JellyfinHDDSpinup.sh`
  - Status=complete, Enable=TRUE, Install_Path set accordingly.
- A **cron guard** that, every 2 minutes, starts the QPKG **only after uptime ≥ 300s** and **only if** the watcher is not already running.

> In QTS App Center, you’ll see **“Jellyfin HDD Spinup”**. On some systems it may appear greyed as it’s a lightweight stub (no real .qpkg file). **That’s fine** — the service still runs via cron and the shell wrapper. You can hide it (Visible=0) or keep it visible.

---

## Configuration

Edit the header of `bin/spinup_ws_login.sh` **before** running `install.sh` (or re‑install after changes):

- `LOG_DIR` — Jellyfin logs folder. Default: `/share/CACHEDEV1_DATA/.qpkg/jellyfin/logs`
- `COOLDOWN` — seconds between spin‑ups. Default: `150`
- `SLEEP` — main loop tick. Default: `2`
- `BOOT_WAIT` — **minimum uptime** (seconds) before doing anything. Default: `300` (5 minutes)
- `ALLOW_PRIVATE` — `0` = only WAN clients (default), `1` = also trigger for LAN/private IPs
- `TRIGGER_PATTERN` — grep‑E pattern for Jellyfin log lines. Default: `WebSocketManager: WS ".*" request`
- `FORCE_MD` — set to e.g. `md3` to force which md array to wake instead of auto‑detecting the largest data md
- `FALLBACK_MD_READ` — keep `0` (OFF). Set `1` only if `sg_start` alone doesn’t wake on your box.

Keep the **cooldown** if you broaden triggers to avoid unnecessary work.

---

## Quick install (QNAP, SSH as **admin**)

1. Upload/unzip this folder on your NAS (e.g. under `/share/Public/jellyfin-HDD-spinup`).  
2. SSH as **admin** (the real `admin`, even an account with admin rights may not work).  
3. Run:
```sh
cd /share/Public/jellyfin-HDD-spinup
sh ./install.sh
```
Verify it’s running (expect **two lines** → parent + worker `tail -f`):
```sh
ps | grep '[s]pinup_ws_login.sh'
```
4. Let disks spindown, then open Jellyfin from **WAN/4G** — the watcher should pre‑wake HDDs on the **home** screen.

---

## Uninstall

```sh
cd /share/Public/jellyfin-HDD-spinup
sh ./uninstall.sh
```
Removes the watcher, the cron guard, the QPKG stub (App Center item), and deletes `/etc/config/jellyfin-hdd-spinup/` and `/.qpkg/JellyfinHDDSpinup/`.
On some systems **“Jellyfin HDD Spinup”** in QTS App Center may still appear, just click remove.

---


## Verifying & Testing

### 1) Detect triggers (no spin‑up)
```sh
cd /share/Public/jellyfin-HDD-spinup
sh tools/test_detect.sh
```
Expected output on WAN access:
```
DETECTED WAN WebSocket 'request' from x.x.x.x @ Thu Sep 25 xx:xx:xx CEST 2025
```

### 2) Manual spin‑up (same actions as the watcher)
```sh
cd /share/Public/jellyfin-HDD-spinup
sh tools/test_spinup_manual.sh
```
This **only** sends SCSI START UNIT to the detected member disks. **It does not read** from md or files.

---

## Files in this repo

```
bin/spinup_ws_login.sh        # watcher (single-instance, WAN filter, cooldown, boot wait, BusyBox-friendly)
install.sh                    # idempotent installer (/etc/config + QPKG stub + cron guard) and starter
uninstall.sh                  # clean removal (kills watcher, removes cron guard, removes QPKG and files)
tools/test_detect.sh          # detect WAN WebSocket “request” lines (no spin-up)
tools/test_spinup_manual.sh   # manual wake: SCSI START UNIT only (no reads)
LICENSE                       # MIT
README.md                     # this file
```

---

## GitHub

```
https://github.com/Damocles-fr/
```

---

## License

MIT — see `LICENSE`.
