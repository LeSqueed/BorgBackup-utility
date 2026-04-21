# Backup Reporting — Push Format

After each successful backup job, the script can POST a JSON payload to a
configured HTTP endpoint. The server is intentionally passive: it only records
what it receives. **Silence is the alert signal** — if a machine stops
reporting, something is wrong. The server does not need to know about machines
in advance; new machines appear automatically on first report.

## Enabling reporting

Add the following to `/etc/backup/backup.conf`:

```bash
REPORT_ENDPOINT="https://your-dashboard.example.com/api/backup"
REPORT_API_KEY_FILE="/etc/backup/report-api-key"
```

The API key file must be root-only (`chmod 600`). If either value is absent or
the key file is missing, reporting is silently skipped — the backup job itself
is unaffected.

Reporting is skipped for dry-run invocations (`--dry-run`).

## Payload format

```json
{
  "schema_version": 1,
  "reported_at": "2026-04-21T02:05:42Z",
  "machine": {
    "name": "my-desktop"
  },
  "status": "success",
  "archive": {
    "name": "my-desktop-2026-04-21T02:00:00",
    "started_at": "2026-04-21T02:00:00.000000",
    "ended_at": "2026-04-21T02:05:41.000000",
    "duration_seconds": 341.7,
    "nfiles": 84312,
    "original_size_bytes": 12453167104,
    "compressed_size_bytes": 8901234567,
    "deduplicated_size_bytes": 314572800
  },
  "repository": {
    "id": "a3f1b2c4d5e6...",
    "location": "ssh://u123456@u123456.your-storagebox.de:23/backups/my-desktop"
  }
}
```

## Field reference

| Field | Type | Description |
|---|---|---|
| `schema_version` | integer | Always `1` for this format. Increment if fields change in a breaking way. |
| `reported_at` | string (ISO 8601 UTC) | When the report was sent, after the full job completed. |
| `machine.name` | string | Value of `BACKUP_NAME` in config, or the system hostname if not set. |
| `status` | string | Always `"success"` — failed jobs do not report. |
| `archive.name` | string | Full borg archive name, including the timestamp suffix. |
| `archive.started_at` | string (ISO 8601) | When borg began writing the archive. |
| `archive.ended_at` | string (ISO 8601) | When borg finished writing the archive. |
| `archive.duration_seconds` | float | Wall-clock duration of the `borg create` step only. |
| `archive.nfiles` | integer | Number of files processed. |
| `archive.original_size_bytes` | integer | Uncompressed size of all backed-up files. |
| `archive.compressed_size_bytes` | integer | Size after compression, before deduplication. |
| `archive.deduplicated_size_bytes` | integer | Net new bytes added to the repository (what this archive actually cost). |
| `repository.id` | string | Borg repository fingerprint (stable across archives). |
| `repository.location` | string | Full SSH URL of the repository. |

## Design notes

- **Only successful jobs report.** A machine that is offline, has a failed
  backup, or has a misconfigured reporting key will simply stop appearing. The
  receiving server should treat any machine that has not reported within its
  expected window as unhealthy.
- **Deduplication vs. compression.** `deduplicated_size_bytes` is the most
  useful size metric for storage capacity tracking — it reflects the marginal
  cost of the backup. `original_size_bytes` is useful for understanding what is
  protected. `compressed_size_bytes` is an intermediate value mainly useful for
  diagnosing compression effectiveness.
- **No file paths are transmitted.** The payload contains only aggregate
  statistics. No filenames, directory structures, or content leave the machine.
- **Authentication.** The endpoint expects `Authorization: Bearer <key>`. The
  key is stored in a root-only file alongside the borg passphrase, following
  the same security model.

## Future extensions

Possible additions in later schema versions (bump `schema_version` on breaking
changes, add optional fields freely on minor additions):

- Per-machine expected backup window (for server-side staleness detection)
- Prune statistics (archives retained/removed)
- Exit warnings from borg (partial backup due to unreadable files)
- Client software version
