# Operator execution checklist — M1B.1 → first controlled bootstrap

Every step below is **mutating** and requires explicit operator approval recorded here
(initials/date/change reference) before execution. Preflight
(`scripts/acceptance/m1b-bootstrap-preflight.sh`) must show no FAIL and the step's prerequisites
as PASS before each step runs. A successful preflight never auto-executes a mutating step.

## Phase A — GitHub security (no OCI dependency)

**Step A1 — create protected environments**
- Exact command: the two `gh api` PUT/POST loops in [github-security.md](github-security.md) §4.
- Target: `eswrops/EventForge` (repo id `1434990962`), environments `production-plan`, `production`.
- Expected resources: 2 environments, each with 1 required reviewer and a main-only deployment branch policy.
- Required identity: `eswrops` (admin).
- Expected effects: workflow dispatches into these environments now require an approval; PR runs cannot enter them.
- Rollback: `gh api -X DELETE repos/eswrops/EventForge/environments/<name>` (removes only the boundary, never credentials — none are attached yet).
- Approval: [ ] date: ______  reviewer: ______

**Step A2 — verify protections before credentials**
- Exact command: `scripts/acceptance/m1b-bootstrap-preflight.sh` → require `gh-environment-production-plan` and `gh-environment-production` PASS.
- Read-only. If BLOCKED, do not proceed to A3.
- Approval: [ ] date: ______  reviewer: ______

**Step A3 — protect `main`** (github-security.md §5), **A4 — harden Actions** (§6, `allowed_actions=selected` + allowlist, SHA pinning if settable), **A5 — record the fork-PR approval setting via the UI**.
- Rollback: the same API endpoints restore previous values (record the current values before changing: `allowed_actions=all`, no protection).
- Approval: [ ] date: ______  reviewer: ______

**Step A6 — attach environment credentials** (only after A2 PASS)
- Targets: `production-plan` ← plan-client `OCI_WIF_CONFIG_JSON`, read-only `CLOUDFLARE_API_TOKEN`, `TF_VARS_PLATFORM`, vars `OCI_REGION=ap-hyderabad-1`, `TF_STATE_BUCKET=eventforge-tfstate-prod`, `OCI_OBJECT_STORAGE_NAMESPACE=axrq1dasyz3y`, `OCI_COMPARTMENT_OCID=<Test compartment>`; `production` ← apply-client JSON + write-scoped Cloudflare token + same vars.
- Values: operator-held; enter via `gh secret set --env <env>` or the UI. Never via shell history, logs, or files in the repository.
- Rollback: delete the secret/variable; rotate the OAuth client secret in the domain.
- Approval: [ ] date: ______  reviewer: ______

**Step A7 — claim verification**
- Dispatch `OIDC claim inspection` (production-plan, main). Require `Result: PASS` with exact matches (numeric ids 1434990962 / 237514587, environment production-plan, ref refs/heads/main). Read-only.
- Approval: [ ] date: ______  reviewer: ______

## Phase B — Vault and bootstrap (operator workstation, local session)

**Step B1 — create the Terraform-state master key** (recommended) or record reuse of `rust-api-secret-key`
- Target: vault `rust-api-secrets` (root compartment), region `ap-hyderabad-1`.
- Expected: 1 AES-256 master key (HSM or software protection per operator policy); record its OCID.
- Rollback: disable/delete the key version (nothing depends on it yet).
- Approval: [ ] date: ______  reviewer: ______

**Step B2 — prepare operator inputs**
- `infra/bootstrap/terraform.auto.tfvars` from the example (tenancy/compartment OCIDs, region, namespace, VM OCIDs, key OCID, email, policy statements from federation.md §C).
- Verify with: `scripts/acceptance/m1b-bootstrap-preflight.sh` → `operator-inputs-bootstrap`, `oci-vault-key` PASS; `tf-version` must be 1.12.2.
- Approval: [ ] date: ______  reviewer: ______

**Step B3 — bootstrap plan review (read-only)**
- Exact command: `cd infra/bootstrap && terraform init -backend=false && terraform plan -input=false -refresh=false -out=/secure/plan-review.tfplan`
- Expected: **11 to add** (10 resources from the offline inventory + the new KMS policy — recount on screen), 0 change, 0 destroy. Any destroy/replacement = STOP.
- Approval: [ ] date: ______  reviewer: ______

**Step B4 — bootstrap apply** *(separate explicit approval — the first `terraform apply` of this project)*
- Exact command: `terraform apply /secure/plan-review.tfplan`
- Target compartment: `Test` (buckets, topic) and tenancy root (IAM); region `ap-hyderabad-1`.
- Expected effects: the 10–11 resources of §B3; nothing else. Existing compute/MySQL/VCN/subnets/LB untouched.
- Required identity: operator user with IAM/bucket/vault rights.
- Rollback: see state-recovery.md §8 (manual removal of newly created resources only, after review).
- Post-steps: confirm subscription email; run state-recovery.md §1 (backend migration) then §2 (backup).
- Approval: [ ] date: ______  reviewer: ______

## Phase C — federation and backend validation (CI, protected environments)

**Step C1 — configure identity-domain trusts + OAuth clients** per environment (federation.md §B).
- Approval: [ ] date: ______  reviewer: ______

**Step C2 — dispatch `OCI backend validation`** (disposable key): require init/write/read/lock/contention/release PASS; record the lock-object suffix (finalizes the plan-identity pattern); retain the validation key name.
- Approval: [ ] date: ______  reviewer: ______

**Step C3 — underprivileged denial probe** (`scripts/ci/verify-oci-backend-denied.sh`) and federation negative tests (federation.md §D). All prohibited operations must be DENIED.
- Approval: [ ] date: ______  reviewer: ______

## Phase D — imports and first plan (CI + operator)

**Step D1 — uncomment import skeletons, fill OCIDs, open PR; require CI green.**
**Step D2 — execute the import checklist** (import-safety.md §4) with a fresh state backup; refresh-only reconciliation must show no unexpected non-no-op.
**Step D3 — dispatch `Production Terraform plan`**; the plan must pass `assert-safe-plan.sh`; save the address/action summary. Any delete/replacement/public-port/unknown-ingress = STOP.
**Step D4 — any `terraform apply` of the platform root remains a separate explicit approval beyond M1B.1 scope.**

## Standing rules

- Never run mutating steps from CI except the two purpose-built validation workflows (disposable key only).
- Never install credentials before the preflight shows environment protections PASS.
- Never relax a policy, remove a `prevent_destroy`, or widen a trust to make a test pass.
- Record every approval with date and reviewer in this file.
