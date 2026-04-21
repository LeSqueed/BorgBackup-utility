# borg-backup

Encrypted, deduplicated backups to a Hetzner Storage Box using [BorgBackup](https://borgbackup.readthedocs.io), managed by a systemd timer.

Tested on Arch Linux. Should work on any systemd-based distro with minor adjustments (swap `pacman` for your package manager in `install.sh`).

## Requirements

- `borgbackup`
- `jq` (only required if reporting is enabled)
- `curl` (only required if reporting is enabled)
- A Hetzner Storage Box with SSH access configured
- An SSH key pair for the storage box

## Installation

```
sudo ./install.sh
```

The script will ask for:

- Hetzner Storage Box hostname (username is derived automatically)
- Local username — substituted into the backup path templates in `conf.d/`
- Path to the SSH key for the storage box
- An encryption passphrase for the borg repository

It will then install the backup script, systemd units, and config files, and optionally initialise the remote repository and enable the daily timer.

Config and data files are never overwritten on subsequent runs unless `--force` is passed.

**Manual installation:** if you copy files by hand instead of using `install.sh`, replace `YOUR_USERNAME` in the installed `conf.d/` and `exclude.d/` files with your actual username.

## Upgrading

To pull in a new version of the backup script and systemd units without touching any config:

```
sudo ./upgrade.sh
```

## Configuration

All config lives under `/etc/backup/` after installation.

### `/etc/backup/backup.conf`

Main configuration: storage box address, retention policy, compression, and optional reporting endpoint. Permissions are `600` (root only).

### `/etc/backup/conf.d/*.conf`

One path per line, comments with `#`. Files are loaded in lexicographic order. Add or remove files to control what gets backed up.

The shipped templates use `YOUR_USERNAME` as a placeholder. `install.sh` replaces this with your actual username automatically. If you edit these files after installation, use your real username directly.

### `/etc/backup/exclude.d/*.conf`

Borg shell-glob patterns, one per line. Files are loaded in lexicographic order. `00-defaults.conf` ships with sensible defaults (browser caches, thumbnails, trash, dev artifacts). Add custom patterns to `90-custom.conf` or drop in additional files.

Pattern syntax: `sh:/path/to/exclude`. See the [borg patterns documentation](https://borgbackup.readthedocs.io/en/stable/usage/help.html#borg-patterns) for details.

## Running manually

```
sudo backup            # run a full backup
sudo backup --dry-run  # test without writing anything
sudo backup --status   # list archives currently stored on the remote
```

## Useful commands

```
journalctl -u borg-backup             # logs from the last run
systemctl list-timers borg-backup     # when the next run is scheduled
```

## Restore

See the [BorgBackup documentation](https://borgbackup.readthedocs.io/en/stable/usage/extract.html) for restore instructions.

Before running any borg commands, set the required environment variables from the installed config:

```bash
source /etc/backup/backup.conf
export BORG_REPO="ssh://${HETZNER_USER:-${HETZNER_HOST%%.*}}@${HETZNER_HOST}:${HETZNER_PORT}${HETZNER_PATH}/$(hostname)"
export BORG_PASSPHRASE="$(cat /etc/backup/passphrase)"
export BORG_RSH="ssh -i ${BORG_SSH_KEY}"
```

Run borg as root (`sudo -E` to pass the exported variables through). Archives are named `MACHINE-YYYY-MM-DDTHH:MM:SS`.

## Reporting

After each successful backup the script can POST a JSON summary to a configured HTTP endpoint. This enables a dashboard showing last backup time, archive size, and deduplication stats per machine. Silence from a machine is the alert signal — no active polling or pre-registration required.

See [reporting-format.md](reporting-format.md) for the payload specification and setup instructions.

## Repository key

During installation, if you initialise the remote repository, the repo key is exported to `/root/borg-repo-key-MACHINE_NAME.txt`. Store this file somewhere safe (password manager, offline USB). Without it you cannot restore backups if the machine is lost, even with the correct passphrase.
