# M1B.1 — Secure bootstrap preparation package

Generated: 2026-10-26T23:43:13Z · Preparation base commit: `15e11867cb508ab76456539936888babaa6118e6` (main) · M1B CI evidence: run [40418147090](https://github.com/eswrops/EventForge/actions/runs/40418147090) at `c38991f`

This package prepares the **first controlled OCI bootstrap and live workload-federation
verification** without executing any of it. Every potentially mutating action is written down
with its exact command, identity, expected effects, and rollback in
[operator-checklist.md](operator-checklist.md). The automated entrypoint
`scripts/acceptance/m1b-bootstrap-preflight.sh` is **read-only by default**.

## What this package contains

| Document | Purpose |
| --- | --- |
| [github-security.md](github-security.md) | Operator-reviewable definitions for the two protected environments, `main` branch protection, and Actions hardening (nothing has been applied to GitHub). |
| [oci-bootstrap.md](oci-bootstrap.md) | Exact proposed bootstrap resource inventory (offline plan verified: 10 creates), Vault/CMK dependency analysis, Always Free consumption estimate. |
| [federation.md](federation.md) | The two distinct workload identities (`production-plan`, `production`): trust requirements, expected OIDC claims, OAuth client requirements, rotation, and the drafted least-privilege IAM statements. |
| [state-recovery.md](state-recovery.md) | State initialization, backup, native-backend authentication, isolated lock validation, encryption validation, version recovery, and rollback procedures. |
| [import-safety.md](import-safety.md) | Import mapping audit against the live M1B inventory, managed vs read-only classification, import execution checklist. |
| [operator-checklist.md](operator-checklist.md) | The ordered, approval-gated execution checklist — the only place mutating steps are defined. |
| [blockers.md](blockers.md) | What is still BLOCKED and the exact operator action for each. |
| [m1b-bootstrap-report.json](m1b-bootstrap-report.json) | Sanitized machine-readable acceptance report for this preparation phase. |

## Headline results of the preparation

- **Immutable GitHub identity verified (numeric REST ids):** repository id `1434990962`,
  owner id `237514587` (`eswrops/EventForge`, public, default branch `main`). GraphQL node ids
  (`R_kgDOVYg5cg`, `U_kgDODigvWw`) were recorded for reference only and are never used in claims.
- **Claim-inspection procedure added:** `scripts/ci/inspect-oidc-claims.sh` (+ fixture tests and the
  protected `OIDC claim inspection` workflow) requires *exact* matches of issuer, audience, subject,
  repository, **numeric** repository/owner ids, ref, ref type, environment, workflow identity, and a
  sane iat/exp window — and fails closed. It prints sanitized claims only, never the JWT.
- **Bootstrap root hardened before first apply:** added the missing Object Storage → KMS service
  policy (`eventforge-objectstorage-kms`); without it, creating the CMK-encrypted state bucket
  fails on the service side. An offline plan (placeholder inputs, no provider API calls) confirms
  the bootstrap root creates exactly 10 resources and touches nothing else.
- **Two portability/security defects fixed before they could bite:** `dtolnay/rust-toolchain` was
  pinned to a SHA that does not exist in that repository (it was the `actions/setup-go` v5.6.0 SHA —
  `frontend.yml`/`release.yml` would have failed at dispatch), and JWT base64url payloads were
  decoded without restoring padding, which BSD `base64` silently truncates.
- **Vault finding:** an active vault `rust-api-secrets` (tenancy root, `ap-hyderabad-1`) already
  exists with one AES/SOFTWARE key `rust-api-secret-key`. It is a secrets key; a dedicated
  Terraform-state master key is recommended (operator decision, see [oci-bootstrap.md](oci-bootstrap.md)).

## What this package deliberately does not do

No `terraform apply`, no imports, no IAM identity creation, no GitHub security mutation, no secret
installation, no application deployment, no Cloudflare/DNS changes, no public ingress. All live
security gates remain BLOCKED exactly as recorded in the M1B evidence until the operator executes
[operator-checklist.md](operator-checklist.md).
