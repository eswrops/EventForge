# Operations runbook

## Host installation

Install the files under `ops/systemd` and `ops/scripts` as root. Create the `eventforge` system account, `/opt/eventforge/releases`, `/etc/eventforge`, and `/var/lib/eventforge`. Put runtime environment files in `/etc/eventforge/api.env` and `/etc/eventforge/worker.env`, mode `0640`, owned by `root:eventforge`.

`/healthz` must only prove that the API process is running. `/readyz` must return HTTP 200 only after the API can complete its lightweight MySQL dependency check. Configure `CORS_ALLOWED_ORIGIN=https://app.<domain>` in `api.env`.

## Release

An approved GitHub Release publishes `eventforge-api-<version>`, `eventforge-worker-<version>`, and `SHA256SUMS`. On one VM, run `eventforge-install-release <version>`, verify local `/readyz`, then repeat on the other VM. The installer retains the previous release and rolls back if either service fails. Do not update both hosts at once.

For private releases, place a fine-grained read-only GitHub token in `/etc/eventforge/release.env` (mode `0600`, root-owned). Rotate it independently of database credentials.

## Backup and restore

The daily systemd timer invokes `eventforge-backup`. It uploads compressed logical dumps through the instance principal and retains 14 days. Test recovery by restoring a selected object into a disposable validation schema, then inspect the expected tables and remove that schema. Never restore over the live `eventforge` schema.

