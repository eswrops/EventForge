# Workload federation — prepared configuration (PREPARED, NOT CONFIGURED)

Status: **Phase 2 preparation complete 2026-10-27 — awaiting explicit OCI-FEDERATION operator
approval. No identity-domain trust, OAuth client, secret, or IAM change exists.** This file
consolidates the live verifications performed before the approval gate, the exact configuration
to be created afterwards, and the sanitized test plan. The authoritative requirements remain
[../m1b-bootstrap/federation.md](../m1b-bootstrap/federation.md) (§A–§D) and checklist steps
10–11 of [../m1b-bootstrap/operator-checklist.md](../m1b-bootstrap/operator-checklist.md).

## 1. Live verification performed before this gate (all read-only, 2026-10-27)

| Requirement (federation.md §A) | Verification |
| --- | --- |
| Numeric repository ID `1434990962` | Live REST `repos/eswrops/EventForge` → `.id = 1434990962` |
| Numeric owner ID `237514587` | Live REST → `.owner.id = 237514587` (`eswrops`) |
| Environments exist and are protected independently | `production-plan` (id 25412942570), `production` (id 25412943777); each: `required_reviewers` (reviewer 237514587, `prevent_self_review: false`) + exactly one custom branch policy (main-only) |
| Ref `refs/heads/main` | Default branch is `main`; enforced by claim inspection |
| Issuer `https://token.actions.githubusercontent.com` / audience `github-actions` | Enforced by `scripts/ci/inspect-oidc-claims.sh` against the live job token |
| Workflow identity (`job_workflow_ref` this repo's workflow `@refs/heads/main`) | Enforced by the inspection script |
| Token validity (numeric `iat`/`exp`, ≤ 3660 s lifetime, not expired/backdated) | Enforced by the inspection script |
| Immutable subject, production-plan | **PASS** — protected inspection run 40453021102 (workflow_dispatch on `main` at `1e06e7f`): exact subject `repo:eswrops@237514587/EventForge@1434990962:environment:production-plan` with all numeric claims and live REST drift check |
| Immutable subject, production | Re-verified by the inspection workflow's dedicated `inspect (production)` job (added 2026-10-27, PR #31); result recorded in the gate table of [README.md](README.md) — **do not configure the apply-side trust until this run reports `Result: PASS`** |

The inspection workflow now runs one independent job per protected environment
(`inspect (production-plan)`, `inspect (production)`), each pinned to its environment with a
distinct concurrency group; both must report `Result: PASS` before any trust is created.

## 2. Two independent identity-domain token-exchange clients (to create ONLY after approval)

| Client | Environment | Subject constraint (exact, immutable) |
| --- | --- | --- |
| `eventforge-github-plan` | `production-plan` | `repo:eswrops@237514587/EventForge@1434990962:environment:production-plan` |
| `eventforge-github-apply` | `production` | `repo:eswrops@237514587/EventForge@1434990962:environment:production` |

Common settings (federation.md §B): resource type `githubactions`; RPST lifetime
`token_exchange_rpst_exp: "60"` minutes; each client's token-exchange policy validates issuer,
audience, and the exact environment-specific immutable subject above, and — where the domain
supports claim conditions — additionally `repository_id = 1434990962` and `ref_type = branch`.
The two clients are never shared: distinct client IDs, distinct secrets, one environment each.

**`OCI_WIF_CONFIG_JSON` template** (the only consumer is `scripts/ci/configure-oci-wif.sh`;
secrets live only as the respective GitHub environment secret, never in Git or logs):

```json
{
  "token_exchange_domain_url": "<identity-domain URL>",
  "token_exchange_client_id": "<client id>",
  "token_exchange_client_secret": "<ENVIRONMENT-SCOPED SECRET>",
  "token_exchange_resource_type": "githubactions",
  "audience": "github-actions",
  "repository": "eswrops/EventForge",
  "repository_owner_id": "237514587",
  "repository_id": "1434990962",
  "environment": "production-plan | production",
  "issuer": "https://token.actions.githubusercontent.com",
  "token_exchange_rpst_exp": "60"
}
```

The helper validates the JWT claims (including both numeric IDs and the immutable subject built
from them), generates a one-run RSA keypair, exchanges JWT + public key for the RPST, refuses
malformed/expired RPSTs, and exports only temporary `OCI_RESOURCE_PRINCIPAL_*` file paths
(0600) — never token material.

## 3. Separate permissions (drafted Stage-2 IAM, gated OFF)

`enable_workload_policies` remains **false**; the two policy resources are created only in
Stage 2, after the first live exchange verifies the claim mapping. The drafted statement sets in
the operator's gitignored `infra/bootstrap/terraform.auto.tfvars` match federation.md §C:

- **plan** (`production-plan`): inspect compartments + read all-resources + read state objects +
  manage objects **restricted to lock objects** (`target.object.name matches /.*lock.*/i`) in the
  state bucket — all conjunctive `all {request.principal.type = 'workload',
  request.principal.claims['github_environment'] = 'production-plan'}` in the Test compartment.
  The state object itself is NOT covered by the manage statement, so the plan identity cannot
  overwrite production state.
- **apply** (`production`): read all-resources + manage `network-security-groups`,
  `load-balancers`, `alarms`, `usage-budgets` + full object management in the state bucket only —
  same conjunctive claim form, Test compartment only, never tenancy-wide, no IAM verbs.

Phase-1 evidence that finalizes the lock pattern: the disposable validation runs observed the
real lock object names (`validation/live-acceptance-<RUN_ID>/terraform.tfstate.lock`), matching
the backend's `<state key>.lock` convention — so the production lock object will be
`bootstrap/terraform.tfstate.lock` and the `/.*lock.*/i` pattern covers it exactly.

**Claim-key honesty:** the drafts use `request.principal.claims['github_environment']`. This
claim name is NOT assumed to exist: at the first live exchange, the actual claim set exposed on
the exchanged principal is read from the OCI Audit events of the exchange (and any introspection
the domain offers) and recorded here before Stage 2 is planned. If the mapped name differs, the
statements are corrected through review — never widened to pass.

## 4. Revocation and rotation

- RPSTs live 60 minutes; any job that may exceed the window re-runs
  `scripts/ci/configure-oci-wif.sh` immediately before its Terraform operation. No API-key
  fallback exists on the CI path.
- Rotate a client secret by creating a new secret on that client in the identity domain and
  updating only that environment's `OCI_WIF_CONFIG_JSON` (one environment at a time; the other
  environment is unaffected).
- Rotate the trust whenever the repository identity changes (rename/transfer): re-verify the
  numeric IDs via the preflight `gh-repo-identity` check first — the immutable subject makes a
  renamed repo fail closed until the trust is re-created for the new numeric identity.
- Revoke by disabling/deleting the client (or its secret) in the identity domain and deleting
  the environment secret in GitHub; RPSTs die within ≤ 60 minutes, one-run keypairs immediately.

## 5. Sanitized test plan (after approval and client creation)

Positive (must PASS before Stage 2):

1. **Exchange:** `configure-oci-wif.sh` in the `production-plan` job exchanges the inspected JWT
   for an RPST and refuses malformed/expired tokens — run inside the protected
   `OCI backend validation` workflow (dispatch input `run_id`), which is pre-wired for
   ResourcePrincipal.
2. **Authorization on disposable keys only:** the same workflow runs
   `verify-oci-backend.sh` + `oci-state-version-recovery.sh` against
   `validation/live-acceptance-<run_id>/` — proving the exchanged principal can actually call
   OCI Object Storage (a successful exchange alone is NOT proof of API authorization).
3. **Claim observation:** read the OCI Audit events for the exchange and the validation API
   calls; record the exact claim names visible on the exchanged principal (expect a
   `github_environment`-carrying claim with value `production-plan`).
4. Repeat 1–3 for `production` after its inspection PASS.

Negative (each must be DENIED; an unexpected success is a gate FAIL):

- Wrong repository, wrong environment, wrong audience, expired/malformed JWT, missing claims →
  exchange refused (fixtures already cover the helper's refusals; live probes use a deliberately
  mismatched disposable JWT source and must fail closed).
- Plan identity attempts a state-object write (non-lock name) → DENIED (the §C control).
- Plan identity attempts an instance mutation → DENIED.
- Apply identity attempts a tenancy-level/IAM change → DENIED.
- The deferred **IAM-DENIAL** probe (`scripts/ci/verify-oci-backend-denied.sh`) runs only under
  an explicitly underprivileged identity (it refuses `DEFAULT` outright); denied operations are
  proven to have written nothing by before/after absence comparison. Potentially mutating
  negative probes use a separately approved disposable target and stop on any success.
- No tokens, secrets, or full JWTs in any evidence: sanitized claim values only.

## 6. Approval boundary (STOP)

Nothing in §2 is executed until the operator explicitly approves **OCI-FEDERATION** referencing
this file. After approval: create exactly the two reviewed clients/trusts, perform the first
live exchanges, verify the claim mapping, and record results here and in the checklist — then,
and only then, may Stage 2 (`enable_workload_policies = true`, 2 creates) be planned under its
own STAGE-2-IAM approval. No Stage-2 IAM apply happens in this phase.
