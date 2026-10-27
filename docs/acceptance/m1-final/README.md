# M1 final acceptance

Working directory for the M1 completion mission (GitHub security → OCI bootstrap → remote
state → federation → imports → additive platform → final report). Gate table refreshed
2026-10-27 after commit `9e4af6a` (PR #20) to reflect the executed Stage-1 bootstrap and the
accepted state migration; the state-identity investigation rows are authoritative in
[remote-state.md](remote-state.md). Dated evidence files (baseline.md, the m1b-bootstrap
records) are preserved unmodified as historical snapshots.

## Files

| File | Content |
| --- | --- |
| [baseline.md](baseline.md) | Phase 0 reconciled starting state (lockdown re-verified live, OCI inventory pristine) |
| [release-operations.md](release-operations.md) | Phase 8 evidence — exit gate **RELEASE-OPERATIONS = PREPARED** |
| [remote-state.md](remote-state.md) | Phase 4 — state-identity root-cause verification for the executed bootstrap migration (lineage/serial reset), offline reproduction, regression tests, preserved ACCEPT_TRANSITION decision |
| [terraform-upstream-issue.md](terraform-upstream-issue.md) | Sanitized upstream Terraform issue draft (migration metadata reset) |
| [live-backend-validation-approval.md](live-backend-validation-approval.md) | Hardened (NOT executed) authorization package for live STATE-LOCKING, STATE-CONTENTION, and STATE-RECOVERY validation on RUN_ID-confined disposable keys; IAM-DENIAL deferred to the federation phase. Merged as `a4e0904`, safety-patched as `938ff89` |
| remaining Phase 9 files | written as their phases execute (architecture, github-security, oci-bootstrap, workload-federation, imports, network-security, monitoring, cost-and-free-tier, acceptance-checklist, blockers, m1-final-report.json) |

## Gate status

| Gate | Status |
| --- | --- |
| GH-SECURITY (Phase 1) | **PASS** — lockdown applied under operator approval and independently re-verified live: 4 required contexts strict+admin-enforced, linear history, 0 approvals (deliberate solo-maintainer config), strict SHA-pinned allowlist, read-only workflow tokens, both environments protected, OIDC inspection re-run PASS (run 40453021102), docs-only PR merge path proven (PRs #10/#11), direct push to main rejected by the protected-branch hook |
| BOOTSTRAP-PLAN (Phase 2) | **PASS (Stage 1)** — executed under explicit operator approval: the dedicated state CMK was created (`state_bucket_kms_key_id` recorded in the tfvars; checklist step 7 resolved), and the bucket `eventforge-tfstate-prod` is live with `NoPublicAccess`, versioning Enabled, and CMK-bound. Exactly the 8 Stage-1 resources planned (preflight 19 PASS / 0 unexpected FAIL; checksum-verified Terraform 1.12.2). Stage-2 workload policies remain gated behind `enable_workload_policies = false` pending federation |
| OCI-BOOTSTRAP (Phase 3) | **PASS (Stage 1)** — 8/8 planned creates applied and verified live (state bucket, backups bucket, version lifecycle, Object Storage KMS policy, dynamic group, instance-backup policy, ONS topic + subscription). Stage-2 (2 GitHub workload-policy creates) is pending the first live token exchange (federation steps 10–11) |
| OCI-REMOTE-STATE (Phase 4) | **PARTIAL (2026-10-27)** — bootstrap migration executed under STATE-MIGRATION approval; the resulting lineage/serial reset was root-caused offline in Terraform 1.12.2 (see [remote-state.md](remote-state.md)) with regression tests committed under `tests/terraform-upstream/`; ACCEPT_TRANSITION preserved (no rewrite, no re-migration). Live STATE-LOCKING/CONTENTION/RECOVERY remain NOT_RUN; IAM-DENIAL deferred to the federation phase — hardened approval package: [live-backend-validation-approval.md](live-backend-validation-approval.md) |
| OCI-FEDERATION (Phase 5) | BLOCKED — needs trusts/clients (steps 10–11); `production` subject not yet inspected in its environment |
| OCI-IMPORTS (Phase 6) | BLOCKED — needs remote state |
| M1C-PLATFORM (Phase 7) | BLOCKED — needs imports |
| RELEASE-OPERATIONS (Phase 8) | **PREPARED** — 12-scenario offline dry-run suite, 5 real installer defects found and fixed (PR #13) |
| M1 final report (Phase 9) | pending |

## Next operator action

1. Approve and execute the hardened live backend validation package
   [live-backend-validation-approval.md](live-backend-validation-approval.md)
   (Option A: operator workstation, `TF_OCI_AUTH=APIKey` +
   `TF_OCI_PROFILE=DEFAULT`, pinned Terraform 1.12.2 via `TERRAFORM_BIN`, and
   the package's concrete RUN_ID), recording observations in its §12 execution
   record. STATE-LOCKING, STATE-CONTENTION, and STATE-RECOVERY stay NOT_RUN
   until then; IAM-DENIAL stays deferred to the federation phase.
2. Federation steps 10–11 of
   [../m1b-bootstrap/operator-checklist.md](../m1b-bootstrap/operator-checklist.md)
   (trusts + clients), then the gated Stage-2 `enable_workload_policies` apply.

Housekeeping: checklist steps 7–9 have executed (CMK created, Stage-1 applied and
verified) but their approval boxes in
[../m1b-bootstrap/operator-checklist.md](../m1b-bootstrap/operator-checklist.md) are
still unfilled — the operator should complete those records from the session logs so
the approval trail matches what ran.
