#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help)
            echo "Usage: sudo $0 [--force]"
            echo "  --force  Overwrite existing config files"
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo ./install.sh)" >&2
    exit 1
fi

# ── Install borg ──────────────────────────────────────────────────────────────

if ! command -v borg &>/dev/null; then
    echo "Installing borgbackup..."
    pacman -S --noconfirm borgbackup
else
    echo "borgbackup already installed: $(borg --version)"
fi

# ── Gather configuration ──────────────────────────────────────────────────────

echo
echo "=== Storage Box ==="
echo

read -rp "Hetzner host [e.g. u123456.your-storagebox.de]: " HETZNER_HOST
HETZNER_USER="${HETZNER_HOST%%.*}"
echo "Username: $HETZNER_USER (derived from host)"

read -rp "Port   [default: 23]:      " HETZNER_PORT
HETZNER_PORT="${HETZNER_PORT:-23}"
read -rp "Path   [default: /backups]: " HETZNER_PATH
HETZNER_PATH="${HETZNER_PATH:-/backups}"

echo
echo "=== Backup Identity ==="
echo

read -rp "Backup name (leave empty to use hostname '$(hostname)'): " BACKUP_NAME

echo
echo "=== Local User ==="
echo

DEFAULT_USER="$(logname 2>/dev/null || id -un)"
read -rp "Username to configure backup paths for [default: $DEFAULT_USER]: " LOCAL_USER
LOCAL_USER="${LOCAL_USER:-$DEFAULT_USER}"

echo
echo "=== SSH Key ==="
echo

DEFAULT_KEY="/home/${LOCAL_USER}/.ssh/hetzner"
read -rp "SSH key path [default: $DEFAULT_KEY]: " SSH_KEY_PATH
SSH_KEY_PATH="${SSH_KEY_PATH:-$DEFAULT_KEY}"

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "Warning: SSH key not found at $SSH_KEY_PATH" >&2
    read -rp "Continue anyway? [y/N]: " cont
    [[ "${cont,,}" == "y" ]] || exit 1
fi

echo
echo "=== Encryption Passphrase ==="
echo "This passphrase protects your backup repository. Store it safely."
echo

while true; do
    read -rsp "Passphrase: " PASSPHRASE; echo
    read -rsp "Confirm   : " PASSPHRASE2; echo
    [[ "$PASSPHRASE" == "$PASSPHRASE2" ]] && break
    echo "Passphrases do not match, try again."
done

if [[ -z "$PASSPHRASE" ]]; then
    echo "Error: passphrase must not be empty." >&2
    exit 1
fi

# ── Create directories ────────────────────────────────────────────────────────

install -d -m 755 /etc/backup
install -d -m 755 /etc/backup/conf.d
install -d -m 755 /etc/backup/exclude.d

# ── Write passphrase ──────────────────────────────────────────────────────────

echo "$PASSPHRASE" > /etc/backup/passphrase
chmod 600 /etc/backup/passphrase
echo "Passphrase written to /etc/backup/passphrase"

# ── Resolve SSH key path ──────────────────────────────────────────────────────

ROOT_KEY="/root/.ssh/hetzner"
if [[ -f "$ROOT_KEY" ]]; then
    echo "SSH key already exists at $ROOT_KEY — using existing key"
    BORG_SSH_KEY="$ROOT_KEY"
else
    echo "Using SSH key at $SSH_KEY_PATH"
    BORG_SSH_KEY="$SSH_KEY_PATH"
fi

# ── Write main config ─────────────────────────────────────────────────────────

DEST_CONF="/etc/backup/backup.conf"
if [[ -f "$DEST_CONF" && $FORCE -eq 0 ]]; then
    echo "Config already exists at $DEST_CONF — skipping (use --force to overwrite)"
else
    sed \
        -e "s|BACKUP_NAME=\"\"|BACKUP_NAME=\"${BACKUP_NAME}\"|" \
        -e "s|HETZNER_HOST=\"\"|HETZNER_HOST=\"${HETZNER_HOST}\"|" \
        -e "s|HETZNER_PORT=\"23\"|HETZNER_PORT=\"${HETZNER_PORT}\"|" \
        -e "s|HETZNER_PATH=\"/backups\"|HETZNER_PATH=\"${HETZNER_PATH}\"|" \
        -e "s|BORG_SSH_KEY=\"\"|BORG_SSH_KEY=\"${BORG_SSH_KEY}\"|" \
        "${SCRIPT_DIR}/config/backup.conf" > "$DEST_CONF"
    chmod 600 "$DEST_CONF"
    echo "Config written to $DEST_CONF"
fi

# ── Install conf.d and exclude.d drop-ins ────────────────────────────────────

install_dropins() {
    local src_dir="$1" dest_dir="$2"
    for src in "${src_dir}"/*.conf; do
        local dest="${dest_dir}/$(basename "$src")"
        if [[ -f "$dest" && $FORCE -eq 0 ]]; then
            echo "Already exists: $dest — skipping"
        else
            sed "s|YOUR_USERNAME|${LOCAL_USER}|g" "$src" > "$dest"
            echo "Installed: $dest"
        fi
    done
}

install_dropins "${SCRIPT_DIR}/config/conf.d"    /etc/backup/conf.d
install_dropins "${SCRIPT_DIR}/config/exclude.d" /etc/backup/exclude.d

# ── Install backup script ─────────────────────────────────────────────────────

cp "${SCRIPT_DIR}/backup.sh" /usr/local/bin/backup
chmod 755 /usr/local/bin/backup
echo "Installed: /usr/local/bin/backup"

# ── Install systemd units ─────────────────────────────────────────────────────

cp "${SCRIPT_DIR}/systemd/borg-backup.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/systemd/borg-backup.timer"   /etc/systemd/system/
systemctl daemon-reload
echo "Installed systemd units"

# ── Offer to initialise borg repository ──────────────────────────────────────

echo
NAME="${BACKUP_NAME:-$(hostname)}"
BORG_REPO="ssh://${HETZNER_USER}@${HETZNER_HOST}:${HETZNER_PORT}${HETZNER_PATH}/${NAME}"
export BORG_REPO
export BORG_PASSPHRASE="$PASSPHRASE"
export BORG_RSH="ssh -i ${BORG_SSH_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

read -rp "Initialise borg repository on the remote now? [Y/n]: " init_repo
if [[ "${init_repo,,}" != "n" ]]; then
    borg init --encryption=repokey-blake2
    echo
    echo "Repository initialised: $BORG_REPO"
    echo
    KEY_EXPORT_PATH="/root/borg-repo-key-${NAME}.txt"
    borg key export "$BORG_REPO" "$KEY_EXPORT_PATH"
    chmod 600 "$KEY_EXPORT_PATH"
    echo "IMPORTANT: repo key exported to $KEY_EXPORT_PATH"
    echo "Store this file somewhere safe. Without it you cannot restore if the machine is lost."
fi

# ── Offer to enable timer ─────────────────────────────────────────────────────

echo
read -rp "Enable and start the daily backup timer? [Y/n]: " enable_timer
if [[ "${enable_timer,,}" != "n" ]]; then
    systemctl enable --now borg-backup.timer
    echo "Timer enabled."
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "=== Installation complete ==="
echo
echo "Repository   : $BORG_REPO"
echo "Config       : /etc/backup/backup.conf"
echo "Backup paths : /etc/backup/conf.d/*.conf"
echo "Excludes     : /etc/backup/exclude.d/*.conf"
echo
echo "Useful commands:"
echo "  sudo backup                         # run backup now"
echo "  sudo backup --dry-run               # test without writing"
echo "  journalctl -u borg-backup           # view last run log"
echo "  systemctl list-timers borg-backup   # next scheduled run"
echo "  sudo ./upgrade.sh                   # update script/units without touching config"
