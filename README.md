# EventForge infrastructure

Terraform and operational scaffolding for the EventForge production deployment.

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

