# Workload federation — configuration created; first exchange BLOCKED on service capability

Status: **OCI-FEDERATION APPROVED and executed 2026-10-27: the two reviewed exchange clients and
the trust configuration are CREATED and active; GitHub environment secrets and repo variables are
installed. The first live token exchange is BLOCKED — the identity domain's token endpoint
refuses the JWT→RPST token-exchange grant (`400 invalid_request`) for every caller, which is a
service-side capability gap with no operator-facing setting; resolution requires Oracle
enablement on the tenancy.** No Stage-2 IAM change exists or is affected. The authoritative
requirements remain [../m1b-bootstrap/federation.md](../m1b-bootstrap/federation.md) (§A–§D) and
checklist steps 10–11 of
[../m1b-bootstrap/operator-checklist.md](../m1b-bootstrap/operator-checklist.md).

## 0. Execution record (2026-10-27, under the OCI-FEDERATION approval)

Created in the DEFAULT identity domain
(`https://idcs-41513dab54d949a5887929115aa16406.identity.oraclecloud.com`, ACTIVE, the tenancy's
only domain; verified via the `oci_identity_domains` data source; the domain contained only
Oracle-managed apps before this work):

| Object | Identity-domain id | Configuration |
| --- | --- | --- |
| Confidential OAuth client `eventforge-github-plan` | `ed4a989e58ae4d69bd2659e890a55e4c` | `CustomAppTemplateId`, active, confidential, OAuth client, server-stored generated secret (0600 local copy), NO admin/app roles |
| Confidential OAuth client `eventforge-github-apply` | `ee225cb9396b4e4c9390076c61a789f3` | same shape; independent secret; never shared with the plan client |
| IdentityPropagationTrust `eventforge-github` | `adbb0c6c8a42480582da7b1ed479c59d` | type JWT; issuer `https://token.actions.githubusercontent.com`; publicKeyEndpoint `https://token.actions.githubusercontent.com/.well-known/jwks`; subjectType `Resource`; allowImpersonation with `impersonatingResource: githubactions` (must equal the exchange's `res_type`); `oauthClients` = BOTH client ids; claimValidations (exact match): `repository=eswrops/EventForge`, `owner=eswrops`, `ref=refs/heads/main`, `ref_type=branch`; claimPropagations: `ext_environment`, `ext_repository`, `ext_ref` (→ RPST `var_ext_*`; `var_name` = JWT `sub`, i.e. the exact immutable subject) |

GitHub side: `OCI_WIF_CONFIG_JSON` installed as the `production-plan` and `production`
environment secrets (built per §2, secrets generated locally into
`/Users/eswr/secure/secrets/eventforge-wif/`, mode 0600, never printed or committed); repo
variables `OCI_REGION`, `TF_STATE_BUCKET`, `OCI_OBJECT_STORAGE_NAMESPACE`,
`TF_VALIDATION_EXPECTED_KMS_KEY_ID`, `TF_VALIDATION_KMS_COMPARTMENT_OCID` set (non-secret
coordinates the pre-wired workflows read). The `OCI WIF exchange probe` workflow
(PR #33/#34, dispatch-only) performs the exchange and prints the sanitized RPST claim mapping.

**Platform-constraint adaptation (documented deviation from §2):** OCI identity domains allow
only **one** IdentityPropagationTrust per issuer (`409 IdentityPropagationTrust with the same
issuer already exists` observed live), so §2's two per-environment trusts are impossible on one
domain. Security-equivalent shape adopted: ONE trust (`eventforge-github`) authorizing BOTH
clients, with claim validations pinning repository + owner + `refs/heads/main` + `branch` —
environment separation is still enforced because (a) a GitHub JWT with an environment subject is
only mintable inside that environment's protection-approved job, (b) each client's secret lives
only in its own environment, and (c) Stage-2 IAM policies will condition on the RPST's
propagated subject claims (`var_name` exact subject / `var_ext_environment`). A per-environment
sub validation cannot be expressed in a single trust (validation rules are conjunctive
exact-match), so environment binding deliberately moved to the IAM layer, which is also where
its Stage-2 review lives.

**BLOCKED: the first live token exchange.** `POST /oauth2/v1/token` with
`grant_type=urn:ietf:params:oauth:grant-type:token-exchange` returns
`400 {"error":"invalid_request","error_description":"The request contains invalid or missing
parameters or duplicate values."}` for EVERY caller variant:

1. Real GitHub OIDC JWT (production-plan job, run
   [40518000542](https://github.com/eswrops/EventForge/actions/runs/40518000542)) with the plan
   client via Basic auth — the identical error;
2. Locally replayed exchange with an UNKNOWN client id — the identical error (client
   authentication is never reached);
3. Known client with `client_id`/`client_secret` as form parameters, with a `scope` parameter,
   with the full RFC 8693 `subject_token_type` URN — identical error;
4. A correctly OCI-signed **user-principal** token-exchange request (SDK-grade request
   signatures) — the same `invalid_request`.

The domain's OpenID metadata lists only the classic grants (no token-exchange), the trust and
clients match the published JWT→RPST procedure
([Exchanging a JSON Web Token for a RPST](https://docs.oracle.com/en-us/iaas/Content/Identity/api-getstarted/token_exchange_grant_type_workload_id-federation.htm)),
and `settings list` exposes no enablement toggle. Conclusion: the JWT→RPST workload-identity
grant is not enabled for this tenancy's DEFAULT domain (ap-hyderabad-1) — a service-side
capability/rollout gap, not a configuration defect. The exchange has NOT succeeded, therefore
per the mission's own rule no claim-mapping evidence exists and Stage-2 IAM work remains
blocked behind it.

**Unblock path (operator action):** raise an Oracle support request (SR) asking to enable the
JWT→RPST token-exchange grant (workload identity federation) for the DEFAULT identity domain of
tenancy `easwarendraece` in `ap-hyderabad-1`, citing the procedure page above and the
`invalid_request` evidence. After enablement: dispatch `OCI WIF exchange probe` in
`production-plan`, then `production`; record the actual `var_name`/`var_ext_*` claim names here
before any Stage-2 IAM statement is reviewed. The clients' secrets should be rotated at
enablement time if the SR takes longer than a quarter.

## 1. Live verification performed before the approval gate (all read-only, 2026-10-27)

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
| Immutable subject, production | **PASS** — the inspection workflow's dedicated `inspect (production)` job (added 2026-10-27, PR #31), run 40510989821 (workflow_dispatch on `main` at `a03bf1d`, 2026-10-27T13:19Z): exact subject `repo:eswrops@237514587/EventForge@1434990962:environment:production`, numeric `repository_id` 1434990962 and `repository_owner_id` 237514587, `ref`/`ref_type` branch@main, `job_workflow_ref` this repository's workflow at `refs/heads/main`, sane 300 s validity window, live REST drift check OK — `Result: PASS (all expected OIDC claims matched exactly)` |

The inspection workflow now runs one independent job per protected environment
(`inspect (production-plan)`, `inspect (production)`), each pinned to its environment with a
distinct concurrency group; both report `Result: PASS` (production-plan: run 40453021102;
production: run 40510989821). Both jobs were re-verified in run 40510989821 after the workflow
extension. No trust may be created if a later inspection drifts.

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
