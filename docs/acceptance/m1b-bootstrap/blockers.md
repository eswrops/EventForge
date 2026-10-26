# M1B.1 blockers

Generated: 2026-10-26T23:43:13Z · Preparation commit: base `15e1186` + this PR · CI evidence for M1B: run [40418147090](https://github.com/eswrops/EventForge/actions/runs/40418147090)

Every remaining gate is BLOCKED on an operator-controlled action below. Nothing here requires
relaxing any protection, and nothing was auto-provisioned.

| # | Blocker | Exact operator action | Unblocks |
| --- | --- | --- | --- |
| 1 | GitHub environments `production-plan`/`production` do not exist | Checklist A1 → A2 ([github-security.md](github-security.md) §4) | Protected federation context |
| 2 | `main` is unprotected | Checklist A3 (branch protection with required PR + the four `Terraform` status checks) | Workflow ref integrity |
| 3 | Actions allowlist/pinning unenforced (`allowed_actions=all`, `sha_pinning_required=false`) | Checklist A4; if SHA-pinning cannot be set via REST for user-owned repos, set via UI and record | Actions hardening |
| 4 | No identity-domain trust / OAuth clients | Checklist C1 ([federation.md](federation.md) §B) — per-environment clients, never shared | Token exchange |
| 5 | No `OCI_WIF_CONFIG_JSON` / Cloudflare tokens / `TF_VARS_PLATFORM` | Checklist A6, after A2 PASS | Backend + plan workflows |
| 6 | Terraform-state CMK decision outstanding | Checklist B1 — dedicated key recommended over reusing `rust-api-secret-key` (AES/SOFTWARE secrets key) | Bootstrap apply |
| 7 | Operator inputs missing (`terraform.auto.tfvars`, policy statements) | Checklist B2 with federation.md §C statement drafts (claim key names confirmed at first exchange) | Bootstrap apply |
| 8 | Bootstrap apply itself | Checklist B3 (plan review) → B4 (apply, separate approval) | State bucket exists |
| 9 | Live backend/federation/isolation gates (M1B Phases 3–6) | C2 → C3, then the M1B runbook sequence | M1B completion |
| 10 | Import reconciliation + first production plan | D1 → D3 | M1C readiness |
| 11 | Fork-PR approval setting not verifiable via REST for user-owned repos | Checklist A5 via web UI | Residual hardening evidence |
| 12 | Sole-reviewer risk (single admin account is also the required reviewer) | Add a second reviewer when available; meanwhile the A1/A6 approvals must be consciously self-reviewed and recorded | Approval independence |

Resolved during this preparation (no longer blockers):

- ~~`dtolnay/rust-toolchain` pinned to a non-existent SHA~~ — fixed to `b725eda525362e7cf34af9a7243cac1e3f01a7ec` (verified against the `stable` branch) in `frontend.yml`/`release.yml`; `frontend.yml`/`release.yml` would have failed at first dispatch.
- ~~Missing Object Storage → KMS service policy~~ — `eventforge-objectstorage-kms` added to `infra/bootstrap/main.tf`; the CMK-encrypted bucket would have failed to create.
- ~~JWT payload decode without padding restoration~~ — fixed in `configure-oci-wif.sh` (both JWT and RPST decode) and the new inspection script; BSD base64 silently truncates unpadded payloads.
- ~~No protected claim-inspection procedure~~ — `scripts/ci/inspect-oidc-claims.sh` + `OIDC claim inspection` workflow added (fixture-tested, sanitized output, fail-closed).
- ~~No reproducible bootstrap scope check~~ — `scripts/acceptance/m1b-bootstrap-preflight.sh` enforces the bootstrap resource allowlist, inventory match, ingress-disabled, shared-network-unmanaged, and imported-protection checks read-only.
