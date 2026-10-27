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
| [live-backend-validation-approval.md](live-backend-validation-approval.md) | Executed authorization package (§12 record filled 2026-10-27) for live STATE-LOCKING, STATE-CONTENTION, and STATE-RECOVERY validation on RUN_ID-confined disposable keys; IAM-DENIAL deferred to the federation phase. Merged as `a4e0904`, safety-patched as `938ff89`, OCI CLI response contracts fixed as `2e2380a`, copy contract fixed as `8d42411`, execution stamped at `ba4be3a` |
| [workload-federation.md](workload-federation.md) | Phase 2 preparation — live OIDC/environment verification, the two independent token-exchange client configurations, permission separation, revocation/rotation, and the sanitized positive/negative test plan. **PREPARED — awaiting OCI-FEDERATION approval** |
| remaining Phase 9 files | written as their phases execute (architecture, github-security, oci-bootstrap, imports, network-security, monitoring, cost-and-free-tier, acceptance-checklist, blockers, m1-final-report.json) |

## Gate status

| Gate | Status |
| --- | --- |
| GH-SECURITY (Phase 1) | **PASS** — lockdown applied under operator approval and independently re-verified live: 4 required contexts strict+admin-enforced, linear history, 0 approvals (deliberate solo-maintainer config), strict SHA-pinned allowlist, read-only workflow tokens, both environments protected, OIDC inspection re-run PASS (run 40453021102), docs-only PR merge path proven (PRs #10/#11), direct push to main rejected by the protected-branch hook |
| BOOTSTRAP-PLAN (Phase 2) | **PASS (Stage 1)** — executed under explicit operator approval: the dedicated state CMK was created (`state_bucket_kms_key_id` recorded in the tfvars; checklist step 7 resolved), and the bucket `eventforge-tfstate-prod` is live with `NoPublicAccess`, versioning Enabled, and CMK-bound. Exactly the 8 Stage-1 resources planned (preflight 19 PASS / 0 unexpected FAIL; checksum-verified Terraform 1.12.2). Stage-2 workload policies remain gated behind `enable_workload_policies = false` pending federation |
| OCI-BOOTSTRAP (Phase 3) | **PASS (Stage 1)** — 8/8 planned creates applied and verified live (state bucket, backups bucket, version lifecycle, Object Storage KMS policy, dynamic group, instance-backup policy, ONS topic + subscription). Stage-2 (2 GitHub workload-policy creates) is pending the first live token exchange (federation steps 10–11) |
| OCI-REMOTE-STATE (Phase 4) | **PASS (2026-10-27, disposable keys)** — bootstrap migration accepted earlier under STATE-MIGRATION approval (lineage/serial reset root-caused in [remote-state.md](remote-state.md), `tests/terraform-upstream/` regression tests, ACCEPT_TRANSITION preserved). Live backend validation **executed** per [live-backend-validation-approval.md](live-backend-validation-approval.md) §12: STATE-LOCKING PASS, STATE-CONTENTION PASS, STATE-RECOVERY PASS on RUN_ID `20261027T130000Z-m1live-r2` from the COPY CONTRACT FIX 1 revision (`8d42411`, stamped `ba4be3a`); run 1 (`20261027T120000Z-m1live`) passed LOCKING+CONTENTION and its RECOVERY failure (CLI 3.95.1 rejects `os object copy --source-bucket` at argument parsing — no API call, no data written) was root-caused and fixed by PR #28 before the fresh-RUN_ID re-run. Validation keys retained; cleanup separately approved only. IAM-DENIAL remains NOT_RUN (deferred to the federation phase by design — §9) |
| OCI-FEDERATION (Phase 5) | **BLOCKED (2026-10-27) at the first live token exchange — service capability.** Under the operator's OCI-FEDERATION approval, the two reviewed confidential clients (`eventforge-github-plan`, `eventforge-github-apply`, no admin roles) and the IdentityPropagationTrust `eventforge-github` (GitHub issuer + JWKS, Resource subject, `impersonatingResource githubactions`, both clients pinned, repository/owner/`refs/heads/main`/branch claim validations, `ext_*` claim propagations) were created in the DEFAULT domain; environment secrets and repo variables installed. OCI allows only one trust per issuer (`409` observed), so §2's two-trust shape was adapted to one trust with both clients — environment binding moved to GitHub environment protections + Stage-2 IAM conditions on the propagated subject claims (documented in [workload-federation.md](workload-federation.md) §0). The exchange itself returns `400 invalid_request` for every caller (real GitHub JWT in run 40518000542, unknown client, body-param auth, OCI-signed user principal) — the JWT→RPST grant is not enabled on this domain/tenancy and no setting exposes it. **Next operator action: Oracle SR to enable workload-identity (JWT→RPST) token exchange for the DEFAULT domain (ap-hyderabad-1)**, then re-run the `OCI WIF exchange probe` workflow per environment |
| OCI-IMPORTS (Phase 6) | BLOCKED — needs remote state |
| M1C-PLATFORM (Phase 7) | BLOCKED — needs imports |
| RELEASE-OPERATIONS (Phase 8) | **PREPARED** — 12-scenario offline dry-run suite, 5 real installer defects found and fixed (PR #13) |
| M1 final report (Phase 9) | pending |

## Next operator action

1. **Unblock OCI-FEDERATION**: raise an Oracle support request to enable the JWT→RPST
   workload-identity token-exchange grant for the DEFAULT identity domain of the tenancy in
   `ap-hyderabad-1` (evidence and wording in
   [workload-federation.md](workload-federation.md) §0). When enabled, dispatch the
   `OCI WIF exchange probe` workflow in `production-plan`, then `production`; the actual RPST
   claim names (`var_name`, `var_ext_*`) must be recorded in workload-federation.md before the
   Stage-2 IAM statements are reviewed — `github_environment` was never assumed to exist.
2. Confirm the **PENDING** ONS email subscription for `eswr.ops@gmail.com` (topic
   `eventforge-operations`, created 2026-10-27T06:07Z) — notification delivery must not be marked
   PASS until the confirmation email is clicked and delivery is verified.
3. Cleanup of the retained validation keys (`validation/live-acceptance-20261027T120000Z-m1live/`,
   `validation/live-acceptance-20261027T130000Z-m1live-r2/`,
   `validation/restore-test-20261027T130000Z-m1live-r2/`) remains a separately approved
   operation naming the RUN_IDs (package §10).

Housekeeping resolved: checklist steps 7–9 are now recorded from actual operator evidence (PR
#29); the Phase-0 state-recovery partial-apply claim is corrected (PR #28).
