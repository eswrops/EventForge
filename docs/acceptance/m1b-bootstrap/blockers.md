# M1B.1.1 blockers

Generated: 2026-10-27 · Corrective base: M1B.1 (`776c9ba`) + this PR · M1B CI evidence: run [40418147090](https://github.com/eswrops/EventForge/actions/runs/40418147090)

Every remaining gate is BLOCKED on an operator-controlled action from the reordered checklist in
[operator-checklist.md](operator-checklist.md) (step numbers below refer to it). Nothing requires
relaxing any protection, and nothing was auto-provisioned.

| # | Blocker | Operator action (checklist step) | Unblocks |
| --- | --- | --- | --- |
| 1 | M1B.1.1 corrections not yet merged | Step 1 — merge this PR | Everything below |
| 2 | GitHub environments `production-plan`/`production` do not exist | Step 3 (approval) → step 4 (create + verify) | Protected federation context |
| 3 | Immutable OIDC subject unconfirmed live | Step 5 — dispatch `OIDC claim inspection`; must show `repo:eswrops@237514587/EventForge@1434990962:environment:<env>` | Trust configuration |
| 4 | `main` is unprotected | Step 6 — branch protection (PR required, 4 CI contexts, admin-enforced, `required_approving_review_count = 0`) + Actions allowlist/pinning | Workflow ref integrity |
| 5 | Terraform-state CMK decision outstanding | Step 7 — dedicated key recommended over reusing `rust-api-secret-key` (AES/SOFTWARE secrets key); record `kms_key_compartment_ocid` | Bootstrap apply |
| 6 | Operator inputs missing (`terraform.auto.tfvars`, policy statements) | Step 8 with federation.md §C statement drafts (claim key names confirmed at first exchange) | Bootstrap apply |
| 7 | Bootstrap apply itself | Step 8 (plan review) → **step 9 (separate apply approval)** | State bucket exists |
| 8 | No identity-domain trust / OAuth clients | Step 10 — per-environment clients bound to the immutable subjects | Token exchange |
| 9 | No `OCI_WIF_CONFIG_JSON` / Cloudflare tokens / `TF_VARS_PLATFORM` | Step 11 — environment-scoped, after steps 4/5 verify protection | Backend + plan workflows |
| 10 | Live backend/federation/isolation gates (M1B Phases 3–6) | Step 12 — disposable-key validation, denial probes, negative tests | M1B completion |
| 11 | Import reconciliation + first production plan | Step 13 — preflight `--mode pre-import`, imports with fresh backup, refresh-only review | M1C readiness |
| 12 | Fork-PR approval setting not verifiable via REST for user-owned repos | Step 6 via web UI | Residual hardening evidence |
| 13 | Single-maintainer era: zero required approvals (deliberate, documented) | Switch to github-security.md §5b (one independent approval) when a second eligible reviewer exists | Approval independence |

Resolved during M1B.1.1 (no longer blockers):

- ~~Underscore Object Storage service subject~~ — hyphenated `objectstorage-<region>` verified
  against the OCI policy reference and locked by `tests/ci/test-bootstrap-policy.sh`; key
  permissions now scoped to the new required `kms_key_compartment_ocid`.
- ~~Name-only OIDC subjects~~ — all expectations and fixtures now use the immutable numeric format
  (`repo:eswrops@237514587/EventForge@1434990962:environment:<env>`), with legacy subjects rejected
  by negative fixtures; the live inspection gate precedes trust configuration.
- ~~Single-maintainer protection deadlock~~ — the recommended configuration requires PRs and CI
  with `required_approving_review_count = 0`; direct pushes remain impossible; the independent-
  approval configuration is pre-drafted as §5b.
- ~~Preflight blind spots~~ — environment rule detection accepts both observed rule-type spellings
  and verifies exact reviewer IDs, the single main-only branch policy, self-review prevention,
  required CI contexts, admin enforcement, and the actions allowlist; explicit pre-bootstrap /
  post-bootstrap / pre-import modes now validate the actual CMK (post-bootstrap) and the import
  template scope (pre-import).
