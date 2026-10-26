# M1B blockers and exact remaining operator actions

Generated: 2026-10-26T23:15:20Z · Validated commit: `c38991ffd0c5964233ee39aec490d8647edb6e1b` · main: `ffb88f97`

Every live security or state gate in Phases 3–6 is **BLOCKED**, not failed: the prerequisites are
operator-controlled and were deliberately not automated (hard safety rules: no automatic OCI
bootstrap, no IAM relaxation, no apply). M1B is **not** complete until the BLOCKED entries in
`federation-validation.json`, `backend-lock-validation.json`, `iam-denial-validation.json`, and the
import preconditions in `import-reconciliation.json` are executed and recorded.

## 1. OCI bootstrap (operator, local session — never CI, never this acceptance run)

1. From the operator workstation (`49.207.205.137/32` is already the break-glass SSH source in
   `rust-api-test-ssh-only`), copy `infra/bootstrap/terraform.tfvars.example` to the ignored
   `terraform.auto.tfvars`. Supply: tenancy/compartment OCIDs, `ap-hyderabad-1`,
   `state_bucket_name = eventforge-tfstate-prod`, a customer-managed `state_bucket_kms_key_id`
   (Vault key must pre-exist), `backup_bucket_name`, the two instance OCIDs (in
   `import-reconciliation.json`), distinct `github_plan_oidc_policy_statements` (OCI reads +
   state/lock objects only) and `github_apply_oidc_policy_statements` (EventForge compartment
   writes only), and notification inputs.
2. `terraform init && terraform apply` from `infra/bootstrap`. This creates the versioned,
   CMK-encrypted state bucket, the backup bucket, the `eventforge-instances` dynamic group, and the
   three IAM policies. Record bucket versioning + KMS IDs in the operator evidence log.
3. Migrate each root to its OCI-native backend key (`bootstrap/`, `platform/`,
   `frontend/terraform.tfstate`) with an approved short-lived operator profile.

## 2. OCI identity-domain trusts (operator, OCI console/CLI)

4. In the identity domain, create one token-exchange OAuth client **per environment** and configure
   the GitHub OIDC trust. Plan trust subject:
   `repo:eswrops/EventForge:environment:production-plan`; apply trust subject:
   `repo:eswrops/EventForge:environment:production`. Validate issuer
   `https://token.actions.githubusercontent.com`, audience `github-actions`, and the repository
   claim. The plan client must receive no OCI resource-write rights.

## 3. GitHub environments and secrets (operator; exact commands)

5. Create both environments with an approval boundary and default-branch restriction:

   ```bash
   gh api -X PUT repos/eswrops/EventForge/environments/production-plan \
     -f wait_timer=0 -F reviewers[0][type]=User -F reviewers[0][id]=$(gh api user --jq .id) \
     -F deployment_branch_policy.protected_branches=false -F deployment_branch_policy.custom_branch_policies=true
   gh api -X POST repos/eswrops/EventForge/environments/production-plan/deployment-branch-policies -f name=main
   gh api -X PUT repos/eswrops/EventForge/environments/production \
     -f wait_timer=0 -F reviewers[0][type]=User -F reviewers[0][id]=$(gh api user --jq .id) \
     -F deployment_branch_policy.protected_branches=false -F deployment_branch_policy.custom_branch_policies=true
   gh api -X POST repos/eswrops/EventForge/environments/production/deployment-branch-policies -f name=main
   ```

6. Store the per-environment secrets and variables (values are operator-held; never paste them into
   files, logs, or this repository):
   - `production-plan`: secret `OCI_WIF_CONFIG_JSON` (plan client, `"environment":"production-plan"`),
     read-only `CLOUDFLARE_API_TOKEN`, secret `TF_VARS_PLATFORM`; vars `OCI_REGION`,
     `TF_STATE_BUCKET`, `OCI_OBJECT_STORAGE_NAMESPACE`, `OCI_COMPARTMENT_OCID`.
   - `production`: secret `OCI_WIF_CONFIG_JSON` (apply client, `"environment":"production"`),
     write-scoped `CLOUDFLARE_API_TOKEN`, secret `TF_VARS_PLATFORM`; same vars.
7. Branch-protect `main` (at minimum: require the `Terraform` status checks and a pull request for
   all pushes; no force push, no delete). Until then the `github.ref == 'refs/heads/main'` gate in
   the dispatch workflows is the only ref check.
8. Optional hardening (recommended): restrict Settings → Actions → allowed actions and enable
   "Require actions to be pinned to a full length commit SHA" (`allowed_actions` is currently `all`,
   `sha_pinning_required` false); enable secret-scanning validity checks; set the fork-PR approval
   requirement in the UI (not exposed via REST for user-owned repos).

## 4. Live validation sequence (after 1–3; each step must be recorded in this directory)

9. Dispatch **OCI backend validation** (production-plan) — proves JWT→RPST, backend init, state
   write/read, lock contention/release on the disposable `validation/…` key. Retain the printed
   validation key for bucket-versioning verification, then run `scripts/ci/verify-oci-backend-denied.sh`
   with an explicitly underprivileged resource principal against the same disposable key.
10. Run the federation negative tests from a scratch workflow with deliberately wrong config JSON
    (wrong repo / environment / audience / expired / missing claims) and record sanitized denials.
11. Import the eight mapped resources into `infra/platform` (OCIDs in `import-reconciliation.json`),
    then run `terraform plan -refresh-only` and review any drift before the first normal plan.
12. Dispatch **Production Terraform plan** (production-plan). It must pass
    `assert-safe-plan.sh` against `platform-safe-plan-policy.json`; save the address/action summary.
13. Phase 6 isolation probes: plan-identity mutation denial, plan-identity production-state
    overwrite denial, VM instance-principal backup-only access (state-bucket denial), Cloudflare
    read-only token zone-write denial.
14. Any `terraform apply` (including the first gated platform apply) remains a separate, explicit
    operator approval. Do not enable API ingress and do not cut over Cloudflare DNS/TLS in M1B.

## Deliberately not done during this acceptance run

- No GitHub environment was created or modified (the operator should create them with reviewers, not
  have CI auto-create unprotected ones on first dispatch).
- No OCI bucket, dynamic group, policy, OAuth client, or Vault key was created.
- No import, no plan against real infrastructure, no apply, no destroy, no force-unlock.
- No protection was weakened anywhere to make testing easier.
