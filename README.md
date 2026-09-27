# ZimaOS Setup

![Bash](https://img.shields.io/badge/Bash-5%2B-green)
![License](https://img.shields.io/github/license/diegochagas/zimaos-setup)
![Version](https://img.shields.io/badge/version-1.1.0-blue)

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
from `steps/apps/compose/` you actually run — this repo makes no assumption about
that:

| Resource | Minimum (light apps: Pi-hole, Vaultwarden, file serving) | Comfortable (full stack, incl. Immich/Jellyfin) |
| --- | --- | --- |
| RAM | ZimaOS/CasaOS's own baseline + a few hundred MB per light container | 8 GB+ — Immich (face/object recognition) and Jellyfin (transcoding) are the heaviest containers |
| CPU | Any board ZimaOS supports | More headroom or GPU passthrough for real-time Jellyfin transcoding and Immich's ML jobs |
| Storage | Internal disk only, for `APPDATA_ROOT` | + external `DATA4TB` (photos/media/Nextcloud data — required, must be mounted at `DATA4TB_MOUNT` before `setup.sh` will run) and `BACKUP4TB` (used by [homelab-backup](https://github.com/diegochagas/homelab-backup), not this repo) |
| Network | LAN connectivity to pull Docker images | Static LAN IP/DNS reservation for `SERVER_IP` (see Not Covered) |

This repo doesn't benchmark or enforce any of the above — `setup.sh`
only checks that the ZimaOS commands (`casaos-cli`, `docker`, ...) are
present and `DATA4TB_MOUNT` is actually mounted before installing anything.

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
the installed apps into [steps/apps/compose/](steps/apps/compose) with paths and secrets replaced by
variables, and [setup.sh](setup.sh) reinstalls them from those files with
the values from `config.sh`.

## Immich Storage Template

Immich's storage template (Administration > Settings > Storage Template —
how uploaded photos/videos are laid out on disk) lives in Immich's own
database, not in a CasaOS compose customization, so it isn't captured by
`export.sh`/`setup.sh` the way ports or volume paths are. It's pinned
declaratively instead:
[steps/apps/immich-config.yml](steps/apps/immich-config.yml) is mounted
read-only into `immich-server` via `IMMICH_CONFIG_FILE`
([Immich docs](https://docs.immich.app/install/config-file/)), which makes
Immich enforce it on every start.

**Trade-off:** setting `IMMICH_CONFIG_FILE` makes Immich disable editing
*any* system setting from the web UI, not just the storage template — the
whole Administration > Settings section becomes read-only. To change the
template (or add other settings), edit `steps/apps/immich-config.yml` and restart the
`immich-server` container; don't try to do it from the web UI while this
file is mounted.

## Jellyfin Live TV Tuners

Jellyfin's Live TV tuners (Dashboard > Live TV > Tuner Devices) live in its
`livetv.xml`, not in the compose file, so `export.sh` doesn't capture them.
They're declared in
[steps/jellyfin-tuners/tuners.txt](steps/jellyfin-tuners/tuners.txt)
instead — one `<name>|<playlist url>` per line, public M3U playlists only
(the file is committed) — and applied by the **Jellyfin Live TV** step of
`setup.sh`.

The step adds only the tuners whose URL isn't in `livetv.xml` yet (existing
ones, including tuners added from the web UI, are left alone), backs up the
file as `livetv.xml.bak-<timestamp>`, and restarts the `jellyfin` container
around the edit, with sudo — the file belongs to the container user. It is
skipped while `livetv.xml` doesn't exist yet (Jellyfin writes it on its
first start). To apply a new line without touching the other apps:

```bash
./setup.sh jellyfin
```

A tuner added from the web UI isn't written back to the list — add its
line to `tuners.txt` too, or it won't come back on a clean install without
a restored AppData backup.

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

- Checks the environment: the ZimaOS commands present (it must run on the
  server), sudo (asked once, up front) and the external drive mounted at
  `DATA4TB_MOUNT`.
- Registers the extra app stores from `config.sh` (by default the
  [big-bear-casaos](https://github.com/bigbeartechworld/big-bear-casaos)
  store), skipping the ones already registered.
- For each file in `steps/apps/compose/`: skips it if the app is already
  installed, otherwise substitutes the `config.sh` values into the compose
  file and installs it with `casaos-cli app-management install`.
- Adds the [Jellyfin Live TV tuners](#jellyfin-live-tv-tuners) (skipped on
  a fresh install, see Step 6).
- Prints a summary and writes a log to `logs/`.

Options: `--dry-run` validates every app through the CasaOS API without
installing anything; passing app names (`./setup.sh jellyfin immich`)
runs only those apps (and the Jellyfin Live TV step only when `jellyfin`
is among them).

Installs continue in the background while ZimaOS pulls the images — watch
the progress in the ZimaOS web UI.

## Step 5 - Restore App Data

Restore the app data root (`APPDATA_ROOT`) and the `DATA4TB` folders from
the workstation backup with
[homelab-backup's `restore.sh`](https://github.com/diegochagas/homelab-backup),
then restart the apps. Tailscale login, the Cloudflared tunnel token and
Vaultwarden's admin token all live inside the restored AppData folders, so
no re-pairing is needed.

## Step 6 - Jellyfin Live TV

Only needed when Jellyfin's AppData was **not** restored in Step 5 (a
restore already brings `livetv.xml` back). Open Jellyfin once and finish
its startup wizard so it writes `livetv.xml`, then run the setup again —
everything else is skipped as already installed:

```bash
./setup.sh jellyfin
```

Channels show up after Jellyfin's "Refresh Guide" task runs (Dashboard >
Scheduled Tasks — run it by hand to skip the wait). See
[Jellyfin Live TV Tuners](#jellyfin-live-tv-tuners).

## Keeping the Export in Sync

After installing or reconfiguring apps in the ZimaOS web UI, refresh the
snapshot on the server and commit:

```bash
cd /DATA/Projects/zimaos-setup && ./export.sh && git add steps/apps/compose && git status
```

`export.sh` fetches the installed compose file of every CasaOS app from the
local app-management API (no sudo needed), replaces the machine-specific
paths and secrets with the `config.sh` variables and rewrites
`steps/apps/compose/`.
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
| `ROMM_DB_PASSWORD` | RomM's MariaDB app user — must match restored mysql data |
| `ROMM_DB_ROOT_PASSWORD` | RomM's MariaDB root password |
| `ROMM_IGDB_CLIENT_ID` / `ROMM_IGDB_CLIENT_SECRET` | IGDB API credentials RomM uses for game metadata scraping |
| `EXTRA_APP_STORES` | Extra app stores to register (optional) |

## Project Layout

```text
setup.sh            Entry point: loads config.sh, lib/ and steps/, then runs
                    the steps in the order listed in run_setup_steps
export.sh           Snapshots the installed apps into steps/apps/compose/
config.sh.example   Template for the required config.sh
lib/
  config.sh         Loads config.sh and validates the required values
                    (shared by setup.sh and export.sh)
  log.sh            Terminal output and the log file
  exec.sh           run (dry-run aware), root file writes, temporary
                    directories and the error handler
  step.sh           run_step, skip_step, warn_step, complete_step and
                    the summary
  casaos.sh         Installed-app queries and the app file list
  preflight.sh      Command, sudo and external drive checks
steps/              One setup step (install_* or configure_*) per file
  <name>.sh         A step without extra files
  <name>/<name>.sh  A step that ships files, kept in the same folder:
  app-stores.sh     Registers EXTRA_APP_STORES
  apps/             apps.sh, the exported compose/ files it installs and
                    immich-config.yml (mounted into immich-server)
  jellyfin-tuners/  jellyfin-tuners.sh and the tuners.txt it applies
```

Every step is a function that installs or configures one thing. It runs
inside `run_step`, which prints the step header and records the result in
the summary:

- Return normally and the step is recorded as installed/configured.
- Call `skip_step "reason"` when there is nothing to do (already installed,
  not initialized yet, nothing configured).
- Call `warn_step "reason"` when the step could not complete but the setup
  should continue.
- Call `complete_step "status"` to record a custom success status (e.g.
  "Install started", "Validated").

Every action that changes the server goes through `run` or
`write_root_file`, which print the action and skip it in `--dry-run` mode.
Any command that fails aborts the setup and reports its file and line.

To add a step, create `steps/<name>.sh` with its function, `source` it in
`setup.sh` and add a `run_step` line to `run_setup_steps` in the position
where it should run. If the step ships files, put it in
`steps/<name>/<name>.sh` with the files beside it and resolve them from
`${BASH_SOURCE[0]%/*}`, as the Jellyfin Live TV step does.

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
- `setup.sh` never uninstalls anything. Apps removed from `steps/apps/compose/` stay
  installed until removed in the web UI; delete the leftover `.yml`
  manually after uninstalling an app.
- Immich's database password is internal to its compose network, but it
  must match the restored `pgdata` when recovering from a backup — keep it
  in `config.sh` and don't rotate it casually.
