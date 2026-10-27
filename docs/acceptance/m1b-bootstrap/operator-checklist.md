# Operator execution checklist — M1B.1.1 → first controlled bootstrap

The corrected order. Every step below that mutates anything requires explicit operator approval
recorded here (initials/date/change reference) before execution. Run the preflight
(`scripts/acceptance/m1b-bootstrap-preflight.sh`, read-only) before each step and require no FAIL.
A successful preflight never auto-executes a mutating step. **API ingress stays disabled
throughout; `enable_api_ingress` remains false in every tfvars and plan.**

1. **Merge these corrective changes.** — Merge the M1B.1.1 PR (CI green) so every later step runs
   against corrected code. Approval: [ ] date: ______ reviewer: ______

2. **Run offline acceptance.** — `scripts/acceptance/run.sh` and `tests/ci/run.sh` must both pass
   (read-only). Include the preflight in all three modes:
   `scripts/acceptance/m1b-bootstrap-preflight.sh --mode pre-bootstrap` (and `--skip-github
   --skip-oci` in CI contexts). Approval: [ ] date: ______ reviewer: ______

3. **Obtain approval for GitHub environment creation.** — Record the decision (approver, scope:
   the two environments, no credentials attached yet).
   Approval: [x] 2026-10-27 — operator review of M1B.1.1 directed M1B.2 step 4 as an "Approved
   GitHub mutation" (create `production-plan` and `production` only; no credentials, no other
   settings). Recorded before execution.

4. **Create and verify GitHub environments.** — Exact commands in
   [github-security.md](github-security.md) §4 for `production-plan` and `production`; then the
   preflight `gh-environment-*` checks must PASS (exact reviewer IDs, exactly one main-only branch
   policy) before anything else touches them. Rollback: delete the environments (no credentials
   exist yet). Approval: [ ] date: ______ reviewer: ______

5. **Inspect actual immutable OIDC claims.** — Dispatch the protected `OIDC claim inspection`
   workflow (production-plan, main). Require `Result: PASS` with the exact numeric subjects
   (`repo:eswrops@237514587/EventForge@1434990962:environment:production-plan`, and for production
   when run there). **Do not configure OCI trusts before this confirms the subject.** Read-only.
   Approval: [ ] date: ______ reviewer: ______

6. **Configure safe branch protection.** — Apply [github-security.md](github-security.md) §5a:
   PRs required, all four CI contexts, admin-enforced, no force pushes/deletion,
   `required_approving_review_count = 0` (deliberate single-maintainer configuration; §5b is the
   recorded future change once an independent reviewer exists). Also §6 Actions hardening
   (allowlist + SHA pinning) and the UI check of the fork-PR setting. Rollback: record prior
   values (unprotected, `allowed_actions=all`) before changing. **APPLIED 2026-10-27** — operator
   instruction "do it" following the M1B.2B report; live values and rollback in
   [../m1b2b/lockdown-applied.json](../m1b2b/lockdown-applied.json); preflight 18 PASS / 0 FAIL,
   `gh-branch-protection-main`, `gh-actions-pinning`, `gh-actions-allowlist` all PASS. The
   fork-PR approval setting check remains a UI-only item (no forks exist; repo is personal).

7. **Review and approve the OCI Vault/key decision.** — Create the dedicated state CMK (or record
   reuse of `rust-api-secret-key`) per [oci-bootstrap.md](oci-bootstrap.md) §2; note the
   `kms_key_compartment_ocid`. Rollback: disable the key version (nothing depends on it yet).
   Approval: [ ] date: ______ reviewer: ______

8. **Generate and review the real bootstrap plan.** — Prepare
   `infra/bootstrap/terraform.auto.tfvars` (incl. `kms_key_compartment_ocid` and the federation
   statements from [federation.md](federation.md) §C); then
   `cd infra/bootstrap && terraform plan -input=false -refresh=false -out=/secure/plan-review.tfplan`.
   Expected: exactly 10 creates, 0 changes, 0 destroys — any destroy/replacement is a STOP.
   Read-only against OCI except state-free planning. Approval: [ ] date: ______ reviewer: ______

9. **Obtain separate bootstrap apply approval.** — This is the first `terraform apply` of the
   project; it needs its own explicit approval, not the plan-review one.
   `terraform apply /secure/plan-review.tfplan` → the 10 resources of
   [oci-bootstrap.md](oci-bootstrap.md) §1; nothing else. Post-steps: confirm the notification
   email; backend migration per [state-recovery.md](state-recovery.md) §1; immediate state backup
   (§2); then re-run the preflight in `--mode post-bootstrap` (buckets expected; versioning + CMK
   validated live). Rollback: §8 of state-recovery.md. Approval: [ ] date: ______ reviewer: ______

10. **Create OCI federation trusts/clients.** — Per-environment token-exchange OAuth clients and
    trust configuration bound to the exact immutable subjects (federation.md §B). Never shared
    between environments. Approval: [ ] date: ______ reviewer: ______

11. **Install protected environment credentials.** — Only after steps 4/5 verify protection:
    `production-plan` ← plan-client `OCI_WIF_CONFIG_JSON`, read-only `CLOUDFLARE_API_TOKEN`,
    `TF_VARS_PLATFORM`, vars; `production` ← apply-client JSON, write-scoped Cloudflare token,
    same vars. Environment-scoped only; values never committed or logged. Rollback: delete the
    secret/variable; rotate the client secret. Approval: [ ] date: ______ reviewer: ______

12. **Validate federation and isolated backend state.** — Dispatch `OCI backend validation`
    (disposable `validation/…` key): init/write/read/lock/contention/release PASS; record the
    lock-object suffix and finalize the plan-identity `target.object.name` pattern; then the
    underprivileged denial probe and the federation negative tests (federation.md §D). Every
    prohibited operation must be DENIED. Approval: [ ] date: ______ reviewer: ______

13. **Begin import reconciliation.** — Preflight `--mode pre-import` (only reviewed mapped
    resources, `prevent_destroy` required, shared network components untouched), then the import
    execution checklist in [import-safety.md](import-safety.md) §4 with a fresh state backup;
    `terraform plan -refresh-only` must show no unexpected non-no-op before the first reviewed
    production plan. Any apply of the platform root remains a separate explicit approval.
    Approval: [ ] date: ______ reviewer: ______

## Standing rules

- Never run mutating steps from CI except the two purpose-built validation workflows (disposable
  key only).
- Never install credentials before environment protection verifies PASS (steps 4→11 ordering).
- Never relax a policy, remove a `prevent_destroy`, or widen a trust to make a test pass.
- Record every approval with date and reviewer in this file.
