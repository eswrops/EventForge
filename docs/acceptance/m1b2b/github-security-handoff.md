# M1B.2B — Operator handoff: GitHub security lockdown

Generated: 2026-10-27 · Corrective PR #8 merged as `08defba8bfee8ee5a37d15f685e67308bcbc9a24`
· **STATUS UPDATE (2026-10-27, operator instruction "do it"): the two changes below have been
APPLIED and verified live — final values and rollback commands are in
[lockdown-applied.json](lockdown-applied.json); preflight 18 PASS / 0 FAIL with
`gh-branch-protection-main`, `gh-actions-pinning`, `gh-actions-allowlist` all PASS.** This
document is retained as the pre-change review record; §1's snapshot below describes the
*pre-change* state used for rollback.

## 1. Live settings snapshot for rollback (captured 2026-10-27, before any change)

| Setting | Current live value | Restore command / note |
| --- | --- | --- |
| Branch protection on `main` | **absent** (`GET …/branches/main/protection` → 404 "Branch not protected") | Rollback: `gh api -X DELETE repos/eswrops/EventForge/branches/main/protection` |
| Actions `allowed_actions` | `all` | Rollback: `gh api -X PUT repos/eswrops/EventForge/actions/permissions -f enabled=true -f allowed_actions=all` |
| Actions `sha_pinning_required` | `false` | Included in the same PUT above (set `-F sha_pinning_required=false` if the field was changed) |
| Selected-actions allowlist | n/a (not configured) | Rollback: the `allowed_actions=all` PUT supersedes it |
| Default workflow permissions | `read`, `can_approve_pull_request_reviews=false` | Already at target — no change planned |
| Environments | `production-plan` (25412942570), `production` (25412943777); reviewer 237514587; `prevent_self_review=false`; main-only branch policies | No change in this step |

## 2. The exact changes to apply on operator approval

**Change 1 — branch protection** ([github-security.md](../m1b-bootstrap/github-security.md) §5a,
payload unchanged): PRs mandatory, the four CI contexts required with `strict: true`,
`enforce_admins: true`, `required_approving_review_count: 0`, force pushes and deletions blocked,
linear history required. The four context names are exactly:

```text
Format and validate (infra/bootstrap)
Format and validate (infra/platform)
Format and validate (infra/frontend)
CI script and workflow checks
```

**Change 2 — strict Actions allowlist** (§6, updated in PR #8):
`allowed_actions=selected` with `github_owned_allowed=false` and `verified_allowed=false` —
no blanket verified-creator access — and exactly four patterns, each verified during M1B.2B
against its source repository:

| Pattern | Verified against | Purpose |
| --- | --- | --- |
| `actions/checkout@11d5960a326750d5838078e36cf38b85af677262` | tag `v4.4.0` (REST `.sha` match) | checkout (PR jobs run `persist-credentials: false`) |
| `actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff` | tag `v5.6.0` | actionlint install |
| `hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd` | tag `v3.1.2` | Terraform 1.12.2 |
| `dtolnay/rust-toolchain@b725eda525362e7cf34af9a7243cac1e3f01a7ec` | `stable` tip at pin time | release/frontend builds (dispatch contexts only) |

The authoritative, test-enforced list is `scripts/ci/action-allowlist.json`;
`tests/ci/test-required-checks.sh` fails CI if any workflow references an action outside it or an
entry loses its full-SHA pin.

## 3. What makes the required checks reliable now (already merged)

- `terraform.yml` has **no `pull_request` path filter**: all four jobs run for every PR, including
  docs-only ones. This PR is the live proof — a docs-only change that must show all four checks.
- The contract test `tests/ci/test-required-checks.sh` fails if a path filter is reintroduced, the
  job or matrix names drift (they are the required contexts), `persist-credentials: false`
  disappears from the PR workflow's checkouts, or an unlisted action is referenced.
- Sole-maintainer merge path: with `required_approving_review_count: 0`, mergeability is gated
  solely on the four passing checks (plus `strict` branch currency), so the sole maintainer can
  merge immediately after CI — no approval is demanded, none can be forged by the GITHUB_TOKEN
  (`can_approve_pull_request_reviews=false`). §5a of github-security.md documents this.

## 4. Verification commands after the operator applies the changes

```bash
# Branch protection active and complete:
gh api repos/eswrops/EventForge/branches/main/protection | jq '."required_status_checks"."contexts", ."enforce_admins", ."allow_force_pushes", ."allow_deletions", ."required_pull_request_reviews"'
# Allowlist active and strict:
gh api repos/eswrops/EventForge/actions/permissions | jq '.allowed_actions, ."sha_pinning_required"'
gh api repos/eswrops/EventForge/actions/permissions/selected-actions | jq '.github_owned_allowed, .verified_allowed, ."patterns_allowed"'
# Full gate check (expects zero FAIL; only known BLOCKED items remain):
scripts/acceptance/m1b-bootstrap-preflight.sh --mode pre-bootstrap
# The sole-maintainer merge path is confirmed by merging the first post-change PR.
```

## 5. Explicitly not done in M1B.2B

No branch protection applied; no Actions permissions modified; no OCI resources created; no
credentials installed; no API ingress; no `terraform apply`/`import`; no Cloudflare changes.
