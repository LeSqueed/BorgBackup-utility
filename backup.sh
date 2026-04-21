#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/backup/backup.conf"
CONF_D="/etc/backup/conf.d"
EXCLUDE_D="/etc/backup/exclude.d"

DRY_RUN=0
STATUS=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --status)  STATUS=1 ;;
        -h|--help)
            echo "Usage: sudo backup [--dry-run] [--status]"
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"

BACKUP_NAME="${BACKUP_NAME:-$(hostname)}"
HETZNER_USER="${HETZNER_USER:-${HETZNER_HOST%%.*}}"

REPORTING_ENABLED=0
REPORT_API_KEY=""
if [[ -n "${REPORT_ENDPOINT:-}" ]]; then
    if [[ -z "${REPORT_API_KEY_FILE:-}" || ! -f "${REPORT_API_KEY_FILE:-}" ]]; then
        echo "Warning: REPORT_ENDPOINT set but REPORT_API_KEY_FILE missing — reporting disabled" >&2
    else
        REPORT_API_KEY=$(<"$REPORT_API_KEY_FILE")
        REPORTING_ENABLED=1
    fi
fi

export BORG_REPO="ssh://${HETZNER_USER}@${HETZNER_HOST}:${HETZNER_PORT}${HETZNER_PATH}/${BACKUP_NAME}"

if [[ ! -f "$BORG_PASSPHRASE_FILE" ]]; then
    echo "Error: passphrase file not found: $BORG_PASSPHRASE_FILE" >&2
    exit 1
fi
BORG_PASSPHRASE=$(<"$BORG_PASSPHRASE_FILE")
export BORG_PASSPHRASE

export BORG_RSH="ssh -i ${BORG_SSH_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o LogLevel=ERROR -o 'HostKeyAlgorithms=+ssh-ed25519-cert-v01@openssh.com,ssh-rsa-cert-v01@openssh.com'"

if [[ $STATUS -eq 1 ]]; then
    echo "Repository : $BORG_REPO"
    echo
    borg list
    exit 0
fi

BACKUP_PATHS=()
if [[ -d "$CONF_D" ]]; then
    for conf_file in "$CONF_D"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            BACKUP_PATHS+=("${line%$'\r'}")
        done < "$conf_file"
    done
fi

if [[ ${#BACKUP_PATHS[@]} -eq 0 ]]; then
    echo "Error: no backup paths defined in $CONF_D" >&2
    exit 1
fi

EXCLUDE_FLAGS=()
EXCLUDE_FILES=()
if [[ -d "$EXCLUDE_D" ]]; then
    for excl_file in "$EXCLUDE_D"/*.conf; do
        [[ -f "$excl_file" ]] || continue
        EXCLUDE_FLAGS+=(--exclude-from "$excl_file")
        EXCLUDE_FILES+=("$excl_file")
    done
fi

ARCHIVE_NAME="${BACKUP_NAME}-$(date +%Y-%m-%dT%H:%M:%S)"

echo "Repository : $BORG_REPO"
echo "Archive    : $ARCHIVE_NAME"
echo "Dry run    : $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"
echo "Paths      :"
printf '  %s\n' "${BACKUP_PATHS[@]}"
if [[ ${#EXCLUDE_FILES[@]} -gt 0 ]]; then
    echo "Excludes   :"
    printf '  %s\n' "${EXCLUDE_FILES[@]}"
fi
echo

CREATE_FLAGS=(--verbose --filter AME --list --stats --show-rc --compression "$COMPRESSION")
[[ $REPORTING_ENABLED -eq 1 && $DRY_RUN -eq 0 ]] && CREATE_FLAGS+=(--json)
[[ $DRY_RUN -eq 1 ]] && CREATE_FLAGS+=(--dry-run)

echo "=== Creating archive ==="
BORG_CREATE_JSON=""
if [[ $REPORTING_ENABLED -eq 1 && $DRY_RUN -eq 0 ]]; then
    BORG_CREATE_JSON=$(borg create "${CREATE_FLAGS[@]}" "${EXCLUDE_FLAGS[@]}" "::${ARCHIVE_NAME}" "${BACKUP_PATHS[@]}")
else
    borg create "${CREATE_FLAGS[@]}" "${EXCLUDE_FLAGS[@]}" "::${ARCHIVE_NAME}" "${BACKUP_PATHS[@]}"
fi

PRUNE_FLAGS=(
    --list --show-rc
    --glob-archives "${BACKUP_NAME}-*"
    --keep-daily   "$KEEP_DAILY"
    --keep-weekly  "$KEEP_WEEKLY"
    --keep-monthly "$KEEP_MONTHLY"
    --keep-yearly  "$KEEP_YEARLY"
)
[[ $DRY_RUN -eq 1 ]] && PRUNE_FLAGS+=(--dry-run)

echo "=== Pruning old archives ==="
borg prune "${PRUNE_FLAGS[@]}"

if [[ $DRY_RUN -eq 0 ]]; then
    echo "=== Compacting repository ==="
    borg compact
fi

echo "=== Done ==="

if [[ $REPORTING_ENABLED -eq 1 && $DRY_RUN -eq 0 ]]; then
    echo "=== Sending backup report ==="
    REPORTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    PAYLOAD=$(jq -n \
        --argjson borg "$BORG_CREATE_JSON" \
        --arg reported_at "$REPORTED_AT" \
        --arg machine_name "$BACKUP_NAME" \
        '{
            schema_version: 1,
            reported_at: $reported_at,
            machine: { name: $machine_name },
            status: "success",
            archive: {
                name: $borg.archive.name,
                started_at: $borg.archive.start,
                ended_at: $borg.archive.end,
                duration_seconds: $borg.archive.duration,
                nfiles: $borg.archive.stats.nfiles,
                original_size_bytes: $borg.archive.stats.original_size,
                compressed_size_bytes: $borg.archive.stats.compressed_size,
                deduplicated_size_bytes: $borg.archive.stats.deduplicated_size
            },
            repository: {
                id: $borg.repository.id,
                location: $borg.repository.location
            }
        }')
    if ! curl -s --fail-with-body -X POST "$REPORT_ENDPOINT" \
            -H "Authorization: Bearer $REPORT_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD"; then
        echo "Warning: failed to deliver backup report to $REPORT_ENDPOINT" >&2
    fi
fi
