# M1B live infrastructure acceptance — summary

Generated: 2026-10-26T23:15:20Z
Validated commit: `c38991ffd0c5964233ee39aec490d8647edb6e1b` (merged to `main` as `ffb88f97` via [PR #1](https://github.com/eswrops/EventForge/pull/1))
CI run: [40418147090](https://github.com/eswrops/EventForge/actions/runs/40418147090) (Terraform 1.12.2, ubuntu-latest)
Live context: OCI tenancy `easwarendraece`, region `ap-hyderabad-1`, namespace `axrq1dasyz3y` (read-only operator session); GitHub repo `eswrops/EventForge` (id `R_kgDOVYg5cg`)

## Verdict

**M1B is NOT complete.** All offline/static gates PASS and CI is green, but every mandatory live
security or state gate (federation, backend locking, IAM isolation, import reconciliation) remains
**BLOCKED** on operator-controlled prerequisites. Per the acceptance rules no BLOCKED check was
recorded as PASS, and no prerequisite was auto-provisioned to unblock testing. Exact operator
actions: [blockers.md](blockers.md).

## Gate status

| Gate | Status | Evidence |
| --- | --- | --- |
| Terraform fmt + validate (1.12.2, all roots) in GitHub Actions | PASS | [ci-validation.json](ci-validation.json), run 40418147090 |
| Provider lockfiles + checksums (linux_amd64 in CI, darwin_arm64 locally) | PASS | [ci-validation.json](ci-validation.json) |
| Offline acceptance harness (12 checks incl. secret scan, ingress-disabled, action pins) | PASS | [offline-harness-report.json](offline-harness-report.json) |
| WIF helper negative fixtures (wrong repo/env, expired, missing claims, failed exchange) | PASS (fixture-level) | run 40418147090 |
| Safe-plan policy fixtures (12 cases: default-deny, replace/delete, public 8080/3306, unknown ingress, protected imports) | PASS | [safe-plan-validation.json](safe-plan-validation.json) |
| GitHub environment security (protected production-plan/production) | **BLOCKED** | [github-environments.json](github-environments.json) — no environments exist |
| Branch protection on `main` | **BLOCKED** | same — main is unprotected |
| Federation JWT→RPST positive + negative (live) | **BLOCKED** | [federation-validation.json](federation-validation.json) — no trusts, no secrets, no OCI dynamic groups/policies |
| OCI backend init/write/read, lock acquire/contention/release, versioning, encryption, recovery | **BLOCKED** | [backend-lock-validation.json](backend-lock-validation.json) — state/backup buckets do not exist |
| Import reconciliation (`-refresh-only`) + first reviewed production plan | **NOT_RUN** | [import-reconciliation.json](import-reconciliation.json) — preconditions unmet |
| IAM isolation denials (plan mutate, state overwrite, VM principal, Cloudflare read-only) | **BLOCKED** | [iam-denial-validation.json](iam-denial-validation.json) |
| Ingress defaults disabled | PASS | harness check + live LB has zero listeners/backend sets |
| Existing security lists not broadened | PASS | platform root declares no security-list resource; live rules captured |

## What was executed live

- Full CI validation in GitHub Actions against commit `c38991f` (three earlier partial runs
  40417204373 / 40417779621 surfaced two real portability bugs — BSD `stat` and `rg` dependence —
  both fixed and re-verified; the fixing commits are recorded in ci-validation.json).
- Read-only OCI inventory capture of the tenancy (VCN/subnets/route table/security lists, both
  E2.1.Micro instances with OCIDs and IPs, flexible LB with no listeners, MySQL.Free endpoint,
  empty Object Storage) — sanitized into [import-reconciliation.json](import-reconciliation.json).
- Live configuration review of the GitHub repository (environments, protection, permissions,
  secrets, collaborators, Actions settings) — [github-environments.json](github-environments.json).

## Existing resource changes

None. No OCI or Cloudflare resource was created, modified, imported, or deleted by this acceptance
activity. No state was written anywhere (no backend exists). No credentials were committed; the
evidence in this directory contains identifiers only.

## Readiness for M1C

Blocked pending the operator sequence in [blockers.md](blockers.md): OCI bootstrap → identity-domain
trusts → protected GitHub environments + secrets → live backend/federation/isolation validation →
import + refresh-only reconciliation → reviewed first plan. M1C work must not begin on the
assumption that federation or backend guarantees hold; they are declared, tested offline, and
fixture-verified, but not yet proven against real OCI resources.
