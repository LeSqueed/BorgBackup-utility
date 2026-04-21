#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo ./upgrade.sh)" >&2
    exit 1
fi

if [[ ! -f /usr/local/bin/backup ]]; then
    echo "Error: no existing installation found (/usr/local/bin/backup missing)" >&2
    echo "Run sudo ./install.sh to perform a fresh install." >&2
    exit 1
fi

echo "Upgrading backup installation..."
echo "Config, passphrase, SSH keys, backup paths, and excludes are not touched."
echo

cp "${SCRIPT_DIR}/backup.sh" /usr/local/bin/backup
chmod 755 /usr/local/bin/backup
echo "Updated: /usr/local/bin/backup"

cp "${SCRIPT_DIR}/systemd/borg-backup.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/systemd/borg-backup.timer"   /etc/systemd/system/
systemctl daemon-reload
echo "Updated: /etc/systemd/system/borg-backup.{service,timer}"

echo
echo "Done. The timer will use the new script on its next run."
echo "To run immediately: sudo backup"
