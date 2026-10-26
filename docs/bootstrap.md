# Bootstrap and state migration

Terraform 1.12 or newer is required because this project uses Terraform's native OCI Object Storage backend. The bootstrap root starts with local state because it creates the remote state bucket itself.

1. Authenticate locally as an OCI operator, set `OCI_COMPARTMENT_OCID`, and run `scripts/oci-free-tier-preflight.sh`. It must confirm the two existing E2.1.Micro VMs, boot-volume capacity, one active 10 Mbps flexible LB, and active MySQL.Free at `10.0.3.18` before any provisioning.
2. Authenticate as an OCI operator with permission to create Object Storage buckets, IAM dynamic groups/policies, Notifications topics, and identity-domain federation objects.
3. Copy `infra/bootstrap/terraform.tfvars.example` to an ignored `terraform.auto.tfvars`, fill in the tenancy, compartment, namespace, region, and GitHub identity values, then run `terraform init && terraform apply` from `infra/bootstrap`.
4. Copy `infra/bootstrap/backend.hcl.example` to ignored `backend.hcl`, populate the emitted bucket name and namespace, and run `terraform init -migrate-state -backend-config=backend.hcl`.
5. Repeat the backend setup for `infra/platform` and `infra/frontend`, using the same state bucket with their distinct keys.
6. Create the GitHub `production` environment, require reviewers, add `CLOUDFLARE_API_TOKEN`, and configure the OCI federation client values required by your identity domain. Do not store an OCI API key in GitHub.

The native OCI backend stores lock objects alongside state. Bucket versioning provides state recovery. Backend credentials must be supplied through OCI environment variables or an approved local OCI profile; never commit them or pass them on the command line.

## OIDC bootstrap boundary

OCI's GitHub JWT-to-RPST integration is tenancy/identity-domain specific. The bootstrap policy in this repository authorizes only a federated `workload` principal for the EventForge compartment. Create the identity-propagation trust in the OCI identity domain with:

- issuer: `https://token.actions.githubusercontent.com`
- audience: `github-actions`
- subject constraint: `repo:<github_owner>/<github_repository>:environment:production`

Record its domain URL, OAuth client ID, and client secret as protected GitHub environment secrets. The CI workflow requests a GitHub OIDC token and invokes the current OCI token-exchange helper configured by those values. Re-run `terraform validate` with the pinned OCI provider after enabling federation; OCI introduced this flow recently and tenant feature availability must be confirmed before first production apply.

