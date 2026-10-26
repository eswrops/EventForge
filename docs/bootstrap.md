# Bootstrap and state migration

Terraform **1.12.2** is the CI-pinned version because this project uses the native OCI Object Storage backend. The bootstrap root starts with local state because it creates the remote state bucket itself.

1. Authenticate locally as an OCI operator, set `OCI_COMPARTMENT_OCID`, and run `scripts/oci-free-tier-preflight.sh`. Save its output with the OCI inventory: OCIDs, private IPs, NSG/security-list rules, and load-balancer configuration.
2. Authenticate as an operator allowed to create Object Storage buckets, IAM policies/dynamic groups, notification resources, and identity-domain federation objects.
3. Copy `infra/bootstrap/terraform.tfvars.example` to ignored `terraform.auto.tfvars`. Supply distinct `github_plan_oidc_policy_statements` and `github_apply_oidc_policy_statements`; the plan policy permits OCI reads plus only Terraform state/lock-object operations, while the apply policy receives only the EventForge writes needed by this repository.
4. Run `terraform init && terraform apply` from `infra/bootstrap`. Provide a customer-managed `state_bucket_kms_key_id`; confirm both buckets are private and versioned, state objects use that key for encryption at rest, and the state bucket lifecycle policy retains prior versions for 30 days.
5. Copy `infra/bootstrap/backend.hcl.example` to ignored `backend.hcl`, populate its namespace and bucket, and migrate the bootstrap state. Repeat for `infra/platform` and `infra/frontend` with their distinct keys. Use an approved short-lived operator profile for this migration; do not commit credentials.
6. Create the reviewed GitHub environments `production-plan` and `production`, restricted to the default branch. Configure separate OCI identity-propagation trusts and OAuth clients for each environment. The plan client must not receive OCI resource-write rights.

The OCI backend stores lock objects alongside state. Bucket versioning supplies recovery history; the 30-day policy bounds noncurrent-version storage. Do not use `terraform state push -force`; restore a prior object version only through the incident procedure with a state backup first.

## GitHub OIDC to OCI RPST

For each protected GitHub environment, set `OCI_WIF_CONFIG_JSON` to a secret JSON object with these fields:

```json
{
  "token_exchange_domain_url": "https://identity-domain.example.com",
  "token_exchange_client_id": "...",
  "token_exchange_client_secret": "...",
  "token_exchange_resource_type": "githubactions",
  "audience": "github-actions",
  "repository": "github_owner/github_repository",
  "environment": "production-plan",
  "issuer": "https://token.actions.githubusercontent.com",
  "token_exchange_rpst_exp": "60"
}
```

The helper obtains a GitHub JWT, verifies its issuer, audience, repository, environment subject, and expiry, then creates a one-run RSA key and exchanges the JWT for an RPST. It rejects malformed or expired RPSTs and exports only temporary `OCI_RESOURCE_PRINCIPAL_*` file paths. The public key submitted to OCI is derived from the same ephemeral private PEM passed to the Resource Principal SDK. Both the OCI provider and the Terraform backend authenticate as `ResourcePrincipal`; no OCI API key belongs in GitHub. Use a separate JSON secret for `production`, with `environment` set to `production`. Any unusually long job must re-exchange immediately before its Terraform operation rather than relying on an expired token.

Configure the `production-plan` trust for `repo:<github_owner>/<github_repository>:environment:production-plan` and the `production` trust for the equivalent `production` subject. Validate issuer, audience, repository subject, and any supported immutable repository claim. Store a read-only Cloudflare API token as `CLOUDFLARE_API_TOKEN` in `production-plan` and the scoped write token under the same name in `production`.

Run the protected **OCI backend validation** workflow before the first plan. It uses a disposable state key and proves backend initialization, state writes, and lock contention without provisioning OCI infrastructure. Record the retained validation key and confirm bucket versioning in the operator evidence log.

