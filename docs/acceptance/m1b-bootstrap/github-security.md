# GitHub security configuration — operator-reviewable definitions

Status: **DEFINED, NOT APPLIED.** Nothing in this file has been executed against GitHub. The
definitions below are the reviewable desired state; applying them is a step in
[operator-checklist.md](operator-checklist.md) and requires explicit operator authorization.
Verified facts are marked ✅; desired-but-missing state is marked ⛔.

## 1. Verified repository identity (Phase 2)

| Fact | Value | Source |
| --- | --- | --- |
| Numeric repository ID ✅ | `1434990962` | REST `GET /repos/eswrops/EventForge` → `.id` |
| Numeric repository owner ID ✅ | `237514587` (`eswrops`) | REST `.owner.id` |
| GraphQL node IDs (reference only — never used in claims) | `R_kgDOVYg5cg` / `U_kgDODigvWw` | REST `.node_id` / `.owner.node_id` |
| Visibility ✅ | `public` | REST `.visibility` |
| Default branch ✅ | `main` | REST `.default_branch` |
| Environment protection capabilities ✅ | Public repositories provide the full set of environment deployment protection rules (required reviewers, deployment branch policies, wait timers) on every plan, including free personal accounts. | GitHub environment documentation; single collaborator `eswrops` (admin) is available as reviewer. |

## 2. Expected immutable OIDC subject claim templates

GitHub's immutable subject format (mandatory for all repositories since 2026-06-18;
`repo:eswrops/EventForge` was created after the 2026-07-15 automatic cutover, so its tokens use it
natively) embeds the verified numeric IDs, which a rename or transfer can never satisfy:

```text
production-plan:  sub = repo:eswrops@237514587/EventForge@1434990962:environment:production-plan
production:       sub = repo:eswrops@237514587/EventForge@1434990962:environment:production
common:           iss = https://token.actions.githubusercontent.com
                  aud = github-actions
                  repository = eswrops/EventForge
                  repository_id = 1434990962
                  repository_owner_id = 237514587
                  ref = refs/heads/main        ref_type = branch
                  job_workflow_ref = eswrops/EventForge/.github/workflows/<file>@refs/heads/main
                  iat/exp: numeric, exp > now, exp - iat <= 3660s
```

Legacy name-only subjects (`repo:eswrops/EventForge:environment:...`) are **rejected** by both
claim checks; fixtures cover them negatively. The first protected live claim inspection (checklist
step 5) must confirm the exact numeric subject before any OCI trust is configured.

## 3. Claim-inspection procedure (added, fixture-tested)

`scripts/ci/inspect-oidc-claims.sh` runs inside a protected job, fetches the job's OIDC JWT, and
validates every claim above with **exact matching** — including the numeric `repository_id` and
`repository_owner_id`, which it cross-checks live against GitHub's REST registry. It records only
sanitized claim values (issuer, audience, subject, ids, ref, environment, workflow ref, expiry
window). The JWT and its signature are never printed, stored, or forwarded; inspection **fails
closed** (exit 65) on any mismatch or missing claim. Fixture coverage: wrong repository, wrong
numeric ids, wrong environment, wrong ref, tag refs, branch-subject (non-environment) tokens,
expired tokens, missing claims, and GitHub-API-outage fail-closed behavior.

Run it via the protected `OIDC claim inspection` workflow (production-plan environment, main-only,
workflow_dispatch) **after** the environments exist, and again inside `configure-oci-wif.sh` at
every federation exchange. Expected claims for both environments are in [federation.md](federation.md).

## 4. Environments — desired state ⛔ (does not exist yet)

Create both environments exactly like this (idempotent; safe to re-run):

```bash
for ENV in production-plan production; do
  gh api -X PUT repos/eswrops/EventForge/environments/$ENV \
    -f wait_timer=0 \
    -F reviewers[0][type]=User \
    -F reviewers[0][id]=237514587 \
    -F deployment_branch_policy.protected_branches=false \
    -F deployment_branch_policy.custom_branch_policies=true
  gh api -X POST repos/eswrops/EventForge/environments/$ENV/deployment-branch-policies -f name=main
done
```

Result per environment: deployment allowed **only from `main`**, one required reviewer, no wait
timer (the reviewer approval is the gate). PR runs can never reach these environments: the
workflow_dispatch workflows are gated on `github.ref == 'refs/heads/main'`, `pull_request` events
never target an environment, and the deployment branch policy blocks any other ref.

**Reviewer independence requirements** (record for every approval):

- The approving reviewer must not be the author of the reviewed change; for a sole operator this
  means the operator must consciously review their own diffs in the environment approval prompt and
  note that in the change record.
- Add a second required reviewer (e.g., a second account in the org) as soon as one is available —
  sole-approver setups are a documented residual risk in [blockers.md](blockers.md).
- Every approval must reference the checklist step in [operator-checklist.md](operator-checklist.md).

**Verification before attaching credentials** (mandatory order): after creating each environment,
run `scripts/acceptance/m1b-bootstrap-preflight.sh` and require
`gh-environment-production-plan` / `gh-environment-production` = PASS **before** storing any secret
or variable in the environment.

## 5. `main` branch protection — desired state ⛔

### 5a. Current configuration (single-maintainer era)

Until an independent reviewer is available, protection must not require approvals — that would
deadlock the sole maintainer — but direct pushes to `main` must be impossible anyway. Every change
travels through a PR whose CI must pass; no human second approval exists yet, and that limitation
is deliberate and recorded here.

```bash
gh api -X PUT repos/eswrops/EventForge/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Format and validate (infra/bootstrap)",
      "Format and validate (infra/platform)",
      "Format and validate (infra/frontend)",
      "CI script and workflow checks"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
JSON
```

- `required_approving_review_count: 0` + the required PR rules mean PRs are mandatory while no
  approval can be demanded from a nonexistent second reviewer; combined with `enforce_admins: true`
  and `required_status_checks.strict`, even the administrator must open PRs and wait for CI.
- Direct pushes are therefore impossible for everyone, including admins.
- Residual limitation (accepted, single-maintainer era): with zero required approvals, the sole
  maintainer self-merges. The GITHUB_TOKEN cannot approve PRs
  (`can_approve_pull_request_reviews: false`, verified by the preflight `gh-token-permissions`
  check), so automation cannot inflate approvals either.

### 5b. Future configuration (apply when another eligible reviewer exists)

The moment a second eligible reviewer is available, switch to one required independent approval:

```bash
gh api -X PUT repos/eswrops/EventForge/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Format and validate (infra/bootstrap)",
      "Format and validate (infra/platform)",
      "Format and validate (infra/frontend)",
      "CI script and workflow checks"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
JSON
```

Record the transition (date, new reviewer) in this file; the preflight accepts either review count
and verifies the review-independent properties (PR required, admin-enforced, no force pushes, no
deletion, all four CI contexts). The four context names are the exact job names of the `Terraform`
workflow (verified in run 40418147090).

## 6. GitHub Actions hardening — desired state ⛔

```bash
# Restrict to a pinned allowlist of trusted actions.
gh api -X PUT repos/eswrops/EventForge/actions/permissions \
  -f enabled=true -f allowed_actions=selected
gh api -X PUT repos/eswrops/EventForge/actions/permissions/selected-actions \
  -F github_owned_allowed=true \
  -F verified_allowed=true \
  -F patterns_allowed[]=actions/checkout@11d5960a326750d5838078e36cf38b85af677262 \
  -F patterns_allowed[]=actions/setup-go@40f1582b2485089dde7abd97c1529aa768e1baff \
  -F patterns_allowed[]=hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd \
  -F patterns_allowed[]=dtolnay/rust-toolchain@b725eda525362e7cf34af9a7243cac1e3f01a7ec

# Minimum GITHUB_TOKEN permissions (already active — verify after changes).
gh api -X PUT repos/eswrops/EventForge/actions/permissions/workflow \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false
```

Current state: `default_workflow_permissions=read` ✅, `can_approve_pull_request_reviews=false` ✅,
`allowed_actions=all` ⛔, `sha_pinning_required=false` ⛔. SHA-pinning enforcement may not be
settable via REST for user-owned repositories; if the repo-level PUT rejects the flag, set it in
Settings → Actions → General via the UI and record the outcome. All committed workflows are already
SHA-pinned to immutable commits (the pin format check runs in CI; the `dtolnay/rust-toolchain`
wrong-SHA defect found and fixed during this preparation is recorded in acceptance-report.json).

**Untrusted PR workflows stay credential-free** ✅: `terraform.yml` (the only `pull_request`
workflow) declares `permissions: contents: read`, references no secrets, no environments, and no
`id-token`; fork PRs therefore receive a read-only token and no OIDC credential.

## 7. Secrets scoping rules (to be applied later, operator-held values)

- Secrets and variables are **environment-scoped only** — never repository-scoped — so that a
  compromised non-protected context cannot read them: `production-plan` gets
  `OCI_WIF_CONFIG_JSON` (plan client), read-only `CLOUDFLARE_API_TOKEN`, `TF_VARS_PLATFORM`, plus
  vars `OCI_REGION`, `TF_STATE_BUCKET`, `OCI_OBJECT_STORAGE_NAMESPACE`, `OCI_COMPARTMENT_OCID`;
  `production` gets the apply client JSON, write-scoped `CLOUDFLARE_API_TOKEN`, `TF_VARS_PLATFORM`,
  and the same vars. Values are never committed, logged, or echoed; `configure-oci-wif.sh` and the
  inspection workflow print sanitized output only.
