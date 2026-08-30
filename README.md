# ZimaOS Setup

![Bash](https://img.shields.io/badge/Bash-5%2B-green)
![License](https://img.shields.io/github/license/diegochagas/zimaos-setup)
![Version](https://img.shields.io/badge/version-1.0.0-blue)

Personal post-install setup for the ZimaOS home server. After a fresh
ZimaOS installation it reinstalls every app with the exact customizations
of the previous installation — published ports, environment values and the
data paths on the external drive (Immich gallery, Nextcloud data and the
media library on `DATA4TB`).

All machine-specific values — paths, the server address and secrets — live
only in the gitignored `config.sh` (see [Configuration](#configuration)),
never in the code or in this README.

This repository is the server-side counterpart of
[linux-mint-setup](https://github.com/diegochagas/linux-mint-setup)
(workstation) and works together with
[homelab-backup](https://github.com/diegochagas/homelab-backup)
(app **data**): this repo reinstalls the apps, homelab-backup's `restore.sh`
brings their data back.

## Requirements

This assumes ZimaOS is already installed and running — see
[Not Covered by This Repository](#not-covered-by-this-repository) for
the initial server setup this repo doesn't handle. Beyond ZimaOS's own
hardware minimums for your board, sizing depends entirely on which apps
from `apps/` you actually run — this repo makes no assumption about
that:

| Resource | Notes |
| --- | --- |
| RAM | Each container (Immich, Nextcloud, Jellyfin, Pi-hole, PostgreSQL, qBittorrent, ...) adds its own footprint on top of ZimaOS/CasaOS itself. Immich (face/object recognition) and Jellyfin (transcoding) are the heaviest — plan for 8 GB+ if you run either, more than ZimaOS's bare minimum. |
| CPU | Jellyfin transcoding and Immich's ML jobs are CPU- (or GPU-, if passed through) bound. A low-power board handles file-serving, Pi-hole and Vaultwarden fine but will struggle to transcode video in real time. |
| Storage | Two external drives beyond the internal disk, per the existing setup: `DATA4TB` (photos/media/Nextcloud data — `setup.sh` refuses to run while it isn't mounted at `DATA4TB_MOUNT`) and `BACKUP4TB` (used by [homelab-backup](https://github.com/diegochagas/homelab-backup), not this repo). Size the internal disk under `APPDATA_ROOT` for container images/databases separately from the media libraries. |
| Network | A static LAN IP/DNS reservation for `SERVER_IP` (see Not Covered) and internet access to pull Docker images during install. |

This repo doesn't benchmark or enforce any of the above — `setup.sh`
only checks that `casaos-cli` is present and `DATA4TB_MOUNT` is actually
mounted before installing anything.

## How ZimaOS Installs Apps

ZimaOS is built on CasaOS. Installing an app from the App Store just renders
a docker-compose template and stores it as a *compose app* in
`/var/lib/casaos/apps/<name>/docker-compose.yml` — including everything
customized in the install dialog. The same API used by the web UI is
available on the server:

- `casaos-cli app-management install -f <compose-file>` installs an app.
- The local app-management API (address in
  `/var/run/casaos/app-management.url`) returns the installed compose file
  of every app, customizations included.

This repository automates both directions: [export.sh](export.sh) snapshots
the installed apps into [apps/](apps) with paths and secrets replaced by
variables, and [setup.sh](setup.sh) reinstalls them from those files with
the values from `config.sh`.

## Step 1 - Bootstrap SSH Access

On a fresh installation, create the user in the ZimaOS web UI first, then
enable SSH under `Settings > Terminal & SSH`. Two quirks of this server:

- sshd penalizes failed or duplicated connection attempts for ~10-20
  seconds (`ssh-copy-id` reliably trips it). Copy the key with a single
  connection instead:

  ```bash
  cat ~/.ssh/id_ed25519.pub | ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no <user>@<server-ip> 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
  ```

- The user's `$HOME` is `/DATA` itself, which is root-owned — if the
  command above fails with a permission error, create the folder once via
  sudo on the server console:

  ```bash
  sudo mkdir -p /DATA/.ssh && sudo chown <user> /DATA/.ssh && sudo chmod 700 /DATA/.ssh
  ```

## Step 2 - Connect the External Drive

Connect the `DATA4TB` USB drive and confirm ZimaOS mounted it at the path
set as `DATA4TB_MOUNT` in `config.sh` (Files app or `lsblk`). `setup.sh`
refuses to install while the mount point is missing, otherwise Docker
would create the app folders on the internal disk and the apps would
silently run against the wrong storage.

## Step 3 - Clone and Configure

On the server:

```bash
mkdir -p /DATA/Projects && cd /DATA/Projects && git clone https://github.com/diegochagas/zimaos-setup.git && cd zimaos-setup && cp config.sh.example config.sh
```

Then edit `config.sh` with the real paths, server address and secrets.
The file is gitignored and **required** — both scripts refuse to run while
it is missing or incomplete, so no value ever needs to exist in the code.
A filled-in copy is kept at
`~/Nextcloud/Documents/Credentials/zimaos-setup__config.sh` on the
workstation (same pattern as the other repos) — restoring it is enough:

```bash
scp ~/Nextcloud/Documents/Credentials/zimaos-setup__config.sh <user>@<server-ip>:/DATA/Projects/zimaos-setup/config.sh
```

## Step 4 - Install the Apps

```bash
./setup.sh
```

What it does:

- Checks the environment: `casaos-cli` present (it must run on ZimaOS) and
  the external drive mounted at `DATA4TB_MOUNT`.
- Registers the extra app stores from `config.sh` (by default the
  [big-bear-casaos](https://github.com/bigbeartechworld/big-bear-casaos)
  store), skipping the ones already registered.
- For each file in `apps/`: skips it if the app is already installed,
  otherwise substitutes the `config.sh` values into the compose file and
  installs it with `casaos-cli app-management install`.
- Prints a summary and writes a log to `logs/`.

Options: `--dry-run` validates every app through the CasaOS API without
installing anything; passing app names (`./setup.sh jellyfin immich`)
installs only those.

Installs continue in the background while ZimaOS pulls the images — watch
the progress in the ZimaOS web UI.

## Step 5 - Restore App Data

Restore the app data root (`APPDATA_ROOT`) and the `DATA4TB` folders from
the workstation backup with
[homelab-backup's `restore.sh`](https://github.com/diegochagas/homelab-backup),
then restart the apps. Tailscale login, the Cloudflared tunnel token and
Vaultwarden's admin token all live inside the restored AppData folders, so
no re-pairing is needed.

## Keeping the Export in Sync

After installing or reconfiguring apps in the ZimaOS web UI, refresh the
snapshot on the server and commit:

```bash
cd /DATA/Projects/zimaos-setup && ./export.sh && git add apps && git status
```

`export.sh` fetches the installed compose file of every CasaOS app from the
local app-management API (no sudo needed), replaces the machine-specific
paths and secrets with the `config.sh` variables and rewrites `apps/`.
Non-CasaOS containers (finances-tracker, homelab-monitor — plain compose
projects in `/DATA/Projects`) are skipped; they have their own repositories.

**Review the diff before committing**: a newly exported app may contain a
secret that still needs a variable in `config.sh` and a matching rule in
`export.sh`'s `template_app()`.

## Configuration

All values live in `config.sh` (gitignored, required — see
`config.sh.example` for the template and the Credentials folder for the
filled-in copy):

| Variable | Purpose |
| -------- | ------- |
| `APPDATA_ROOT` | App data root on the internal drive |
| `DATA4TB_MOUNT` | External data drive mount point |
| `IMMICH_GALLERY_DIR` | Immich photo/video library |
| `NEXTCLOUD_DATA_DIR` | Nextcloud user data |
| `JELLYFIN_MEDIA_DIR` | Jellyfin media library |
| `QBITTORRENT_DOWNLOADS_DIR` | qBittorrent download root |
| `SERVER_IP` | LAN address used in app Web UI links |
| `TZ`, `PUID`, `PGID` | Container environment |
| `PIHOLE_WEB_PASSWORD` | Pi-hole admin UI password |
| `POSTGRESQL_DB/USER/PASSWORD` | Shared PostgreSQL app (used by finances-tracker) |
| `IMMICH_DB_PASSWORD` | Immich internal database — must match restored pgdata |
| `EXTRA_APP_STORES` | Extra app stores to register (optional) |

## Not Covered by This Repository

Settings that live outside CasaOS app management still need the ZimaOS web
UI after a reinstall:

- Creating the ZimaOS user account and enabling SSH (Step 1).
- Network configuration and the router's static IP/DNS reservation.
- Storage layout: adopting the internal data partition and the external
  drives (`DATA4TB`, `BACKUP4TB`).
- Samba shares of the `DATA4TB` folders.
- The sudoers rule for remote backups and the root systemd backup timer —
  both handled by
  [homelab-backup](https://github.com/diegochagas/homelab-backup)
  (`zimaos/install-timer.sh`).
- Non-CasaOS compose projects in `/DATA/Projects`
  (finances-tracker, homelab-monitor) — clone and start them from their own
  repositories.

## Notes

- The exported compose files pin images by digest, so a reinstall brings
  back the exact versions that were running. Update apps through the ZimaOS
  web UI and re-run `export.sh` afterwards.
- `setup.sh` never uninstalls anything. Apps removed from `apps/` stay
  installed until removed in the web UI; delete the leftover `.yml`
  manually after uninstalling an app.
- Immich's database password is internal to its compose network, but it
  must match the restored `pgdata` when recovering from a backup — keep it
  in `config.sh` and don't rotate it casually.
