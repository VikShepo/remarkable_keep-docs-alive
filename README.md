# reMarkable Sync Keepalive

This package installs a small background job on a reMarkable 2 or reMarkable Paper Pro.

It does not try to fake visible taps on the UI. Instead, it refreshes the same per-document metadata that reMarkable updates when a document is opened, then lets `xochitl` push those changes while Wi-Fi is available. That is the stable SSH-safe path here.

## What it does

- Scans `/home/root/.local/share/remarkable/xochitl/*.metadata`
- Selects non-deleted `DocumentType` items older than 30 days by `lastOpened`
- Updates `lastOpened`, `lastModified`, `metadatamodified`, `modified`, and `synced`
- Restarts `xochitl` once so the tablet reloads the changed metadata
- Waits for `synced: true` on each refreshed item
- Runs hourly through `systemd`, but only changes documents when they cross the 30-day threshold

## Why this exists

reMarkable's support pages currently state that, without Connect, documents that have not been opened and synced for more than 50 days stop syncing across devices:

- [Pair your reMarkable with the cloud](https://support.remarkable.com/articles/Knowledge/Pair-your-reMarkable-with-the-cloud)
- [Help with sync and the reMarkable cloud](https://support.remarkable.com/articles/Knowledge/Help-with-sync-and-the-reMarkable-cloud)

## Files

- `remarkable-keepalive.sh`: device-side script
- `remarkable-keepalive.service`: `systemd` oneshot service
- `remarkable-keepalive.timer`: hourly timer with catch-up on boot
- Copy `remarkable-keepalive.sh` to `/home/root/bin/remarkable-keepalive.sh`
- Copy `remarkable-keepalive.service` to `/etc/systemd/system/remarkable-keepalive.service`
- Copy `remarkable-keepalive.timer` to `/etc/systemd/system/remarkable-keepalive.timer`

## Copy files with scp

From your PC, upload the files to a staging folder on the tablet:

```sh
ssh root@10.11.99.1 "mkdir -p /home/root/bin /home/root/remarkable-keepalive-install"
scp remarkable-keepalive.sh remarkable-keepalive.service remarkable-keepalive.timer root@10.11.99.1:/home/root/remarkable-keepalive-install/
```

Replace `10.11.99.1` with your tablet IP if you are using Wi-Fi instead of USB.

## Install on the tablet

SSH into the tablet and move the uploaded files into place:

```sh
mkdir -p /home/root/bin
cp /home/root/remarkable-keepalive-install/remarkable-keepalive.sh /home/root/bin/remarkable-keepalive.sh
chmod 0755 /home/root/bin/remarkable-keepalive.sh
cp /home/root/remarkable-keepalive-install/remarkable-keepalive.service /etc/systemd/system/remarkable-keepalive.service
cp /home/root/remarkable-keepalive-install/remarkable-keepalive.timer /etc/systemd/system/remarkable-keepalive.timer
chmod 0644 /etc/systemd/system/remarkable-keepalive.service /etc/systemd/system/remarkable-keepalive.timer
systemctl daemon-reload
systemctl enable --now remarkable-keepalive.timer
systemctl start remarkable-keepalive.service
```

## Uninstall on the tablet

```sh
systemctl disable --now remarkable-keepalive.timer 2>/dev/null || true
systemctl stop remarkable-keepalive.service 2>/dev/null || true
rm -f /etc/systemd/system/remarkable-keepalive.service
rm -f /etc/systemd/system/remarkable-keepalive.timer
rm -f /home/root/bin/remarkable-keepalive.sh
rm -f /etc/default/remarkable-keepalive
systemctl daemon-reload
systemctl reset-failed remarkable-keepalive.service remarkable-keepalive.timer 2>/dev/null || true
```

## Optional configuration

Create `/etc/default/remarkable-keepalive` if you want to change behavior:

```sh
THRESHOLD_DAYS=30
SYNC_TIMEOUT_SEC=900
POLL_INTERVAL_SEC=10
RESTART_XOCHITL=1
DRY_RUN=0
XOCHITL_DIR=/home/root/.local/share/remarkable/xochitl
```

## Logs and checks

```sh
tail -f /home/root/.local/share/remarkable-keepalive/remarkable-keepalive.log
systemctl status remarkable-keepalive.timer --no-pager
systemctl status remarkable-keepalive.service --no-pager
```

## Important tradeoff

There is no stable, documented headless API for literally opening every PDF, EPUB, and notebook in the background over SSH on both current device families. This implementation uses metadata refresh plus sync confirmation instead. That is much less brittle than screen-coordinate automation and is the safer option to keep running after OS updates.
