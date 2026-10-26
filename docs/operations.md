# Operations runbook

## Host installation

Install the files under `ops/systemd` and `ops/scripts` as root. Create the `eventforge` system account, `/opt/eventforge/releases`, `/etc/eventforge`, and `/var/lib/eventforge`. Put runtime environment files in `/etc/eventforge/api.env` and `/etc/eventforge/worker.env`, mode `0640`, owned by `root:eventforge`.

`/healthz` must only prove that the API process is running. `/readyz` must return HTTP 200 only after the API can complete its lightweight MySQL dependency check. Configure `CORS_ALLOWED_ORIGIN=https://app.<domain>` in `api.env`.

## Production-readiness evidence

Before enabling `enable_api_ingress`, retain the following evidence with the release record:

1. OCI inventory, preflight output, import commands, and refresh-only plans have been reviewed.
2. The protected `production-plan` workflow completed with the read-only OCI and Cloudflare identities; its address/action summary matched the committed safe-plan policy.
3. The OCI backend validation workflow completed. It proves an RPST-authenticated backend read/write and rejects a concurrent lock contender on a disposable state key.
4. The OCI identity-domain trust rejects a GitHub token from the wrong repository or environment. Perform this negative test only from trusted workflow code and keep the exchange-client secret confined to a reviewer-protected test environment.
5. The VM dynamic group can write backup objects but cannot inspect or read the Terraform-state bucket. Confirm the bucket policy and a denied access attempt.
6. Both VMs return local `/readyz` responses after their lightweight MySQL checks. Confirm the Cloudflare zone is already Full (strict) before setting `enable_api_ingress = true`.

After ingress is enabled, request the API hostname until both instance identifiers are observed, stop one API service, confirm the load balancer removes it, then restart it and confirm it returns. Verify API responses are not cached at Cloudflare. A certificate rotation requires a reviewed `origin_certificate_generation` bump and a narrowly scoped safe-plan exception; verify the new listener certificate is active before allowing deletion of the previous name.

## Release

An approved GitHub Release publishes `eventforge-api-<version>`, `eventforge-worker-<version>`, and `SHA256SUMS`. On one VM, run `eventforge-install-release <version>`, verify local `/readyz`, then repeat on the other VM. The installer retains the previous release and rolls back if either service fails. Do not update both hosts at once.

For private releases, place a fine-grained read-only GitHub token in `/etc/eventforge/release.env` (mode `0600`, root-owned). Rotate it independently of database credentials.

## Backup and restore

The daily systemd timer invokes `eventforge-backup`. It uploads compressed logical dumps through the instance principal and retains 14 days. Test recovery by restoring a selected object into a disposable validation schema, then inspect the expected tables and remove that schema. Never restore over the live `eventforge` schema.

