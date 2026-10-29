# EventForge infrastructure

Terraform and operational scaffolding for the EventForge production deployment.

## Current deployment status (2026-10-29)

- **B5 RESOLVED and hardened**: MySQL `rust-api-heatwave` is ACTIVE inside
  `eventforge-db-nsg`; the transitional subnet-wide `10.0.2.0/24 → 3306`
  security-list rule has been REMOVED. The app-NSG↔db-NSG 3306 pairing is the
  sole live-proven MySQL path (post-removal greeting evidence from BOTH VMs,
  2026-10-28T23:23Z).
- **SSH is /32-restricted on both controls** (app security list and app NSG
  both pin the operator's current IP, port 22 only).
- **Diagnostics IAM policy REMOVED**; IAM state holds exactly the two MySQL
  resource-principal policies. Platform state serial 14, lineage
  `cdda242b…`; IAM state serial 3, lineage `2d169472…`.
- **Reproducibility verified 2026-10-29** (read-only audit): refreshing plan
  with pinned Terraform 1.12.2 = zero changes, zero drift — see
  [docs/acceptance/m1-local/post-b5-reproducibility-audit.md](docs/acceptance/m1-local/post-b5-reproducibility-audit.md).
- Still outstanding: ONS subscription confirmation **PENDING** (B3);
  OCI-FEDERATION **DEFERRED** (Oracle SR); application deployment
  **NOT_STARTED** (M2). Public API ingress remains disabled (LB zero
  listeners).

## Layout

- `infra/bootstrap` creates the versioned OCI Terraform-state bucket, backup bucket, and OCI IAM foundations.
- `infra/platform` imports and configures the existing OCI network, compute, MySQL, and public load balancer; it also owns Cloudflare DNS and origin TLS.
- `infra/frontend` publishes the static WebAssembly frontend as a Cloudflare Worker with static assets.
- `ops` contains systemd, backup, and pull-based release templates for the two existing VMs.

The configuration deliberately has no default credentials, resource OCIDs, IP addresses, or domain name. Copy each `*.tfvars.example` to an ignored `*.auto.tfvars` file and replace every placeholder before running Terraform.

## Safe order of operations

1. Read [bootstrap.md](docs/bootstrap.md) and run the bootstrap root locally with a short-lived operator session.
2. Configure the native OCI backend for each root from its `backend.hcl.example`, then migrate its local state.
3. Follow [imports.md](docs/imports.md). The first platform plan must match `scripts/ci/platform-safe-plan-policy.json`; do not apply an unapproved update, replacement, or deletion.
4. Apply the platform root with `enable_api_ingress = false`, install the `ops` files on each VM, then enable the protected GitHub workflows.
5. Build and release the frontend only after the platform stack has created DNS, TLS, and the Worker custom domain.

## Security properties

- The state and backup buckets are separate, private, versioned, and never exposed as Terraform outputs.
- Existing OCI resources are managed with `prevent_destroy`; subnet security lists are read, not replaced.
- Cloudflare Origin CA private-key material is intentionally sensitive state. Restrict bucket/object access to the bootstrap operator and protected production CI.
- CI never SSHes to instances. Instance updates are downloaded by the instances after checksum verification.
- Public API ingress is disabled by default. It can be enabled only after both hosts pass `/readyz` and the shared-zone owner confirms Cloudflare Full (strict) mode.

See [operations.md](docs/operations.md) for VM installation, backup/restore, release, and incident procedures.

