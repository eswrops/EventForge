# OCI workload federation — two distinct identities

Status: **FULLY SPECIFIED, NOT CONFIGURED.** No identity-domain trust, OAuth client, or IAM
statement exists yet (verified live during M1B: no dynamic groups besides the planned instance
group, no GitHub/WIF policies, no `OCI_WIF_CONFIG_JSON` secret anywhere in GitHub). Federation must
not be assumed functional until an actual token exchange **and a signed API request** succeed —
that is checklist step F in [operator-checklist.md](operator-checklist.md).

## A. Identity requirements — common

| Requirement | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Audience | `github-actions` |
| Subject (plan) | `repo:eswrops@237514587/EventForge@1434990962:environment:production-plan` |
| Subject (apply) | `repo:eswrops@237514587/EventForge@1434990962:environment:production` |
| Numeric repository ID | `1434990962` |
| Numeric repository owner ID | `237514587` |
| Ref | `refs/heads/main` (`ref_type: branch`) |
| Workflow identity | `job_workflow_ref` starts with `eswrops/EventForge/.github/workflows/` and ends with `@refs/heads/main` |
| Validity | numeric `iat`/`exp`; `exp > now`; lifetime ≤ 3660 s |

The subjects use GitHub's immutable format (numeric IDs mandatory since 2026-06-18); legacy
name-only subjects are rejected. These are exactly the claims
`scripts/ci/inspect-oidc-claims.sh` enforces; run the protected `OIDC claim inspection` workflow
once per environment after the environments exist and require `Result: PASS` — **before** any OCI
trust is configured — and again inside `configure-oci-wif.sh` at every federation exchange.

## B. Identity-domain trust requirements (per environment)

Create **two independent** trust configurations in the OCI identity domain (never share clients):

1. **Token-exchange OAuth client** `eventforge-github-plan` for production-plan and
   `eventforge-github-apply` for production, each with its own client id + secret. Client secrets
   are stored only as the respective environment's `OCI_WIF_CONFIG_JSON` secret; they are never
   committed, shared across environments, or printed.
2. Each client's token-exchange policy validates the GitHub OIDC JWT: issuer, audience, and the
   environment-specific **immutable subject** from §A
   (`repo:eswrops@237514587/EventForge@1434990962:environment:<environment>`). Constrain to the
   exact subject strings — never name-only forms — and, where the domain supports claim conditions,
   to `repository_id = 1434990962` and `ref_type = branch`.
3. Resource type `githubactions`, RPST lifetime 60 minutes
   (`token_exchange_rpst_exp: "60"`; accepted range 1–720).

**Protected configuration fields** of `OCI_WIF_CONFIG_JSON`
(`scripts/ci/configure-oci-wif.sh` is the only consumer): `token_exchange_domain_url`,
`token_exchange_client_id`, `token_exchange_client_secret`, `token_exchange_resource_type`,
`audience`, `repository` (`eswrops/EventForge`), **`repository_owner_id` (`237514587`),
`repository_id` (`1434990962`)**, `environment` (`production-plan` / `production`), `issuer`,
`token_exchange_rpst_exp`. The helper validates the JWT claims — including the numeric repository
and owner IDs and the immutable subject built from them — generates a **one-run RSA keypair**,
exchanges JWT+public key for the RPST, refuses malformed/expired RPSTs, and exports only temporary
`OCI_RESOURCE_PRINCIPAL_*` file paths (0600) — never token material.

**Expiration and rotation:**

- RPSTs live 60 minutes; any job that may exceed the window re-runs `configure-oci-wif.sh`
  immediately before its Terraform operation; there is no fallback to API keys.
- Rotate a client secret by creating a new one in the domain and updating that environment's
  `OCI_WIF_CONFIG_JSON` (update one environment at a time; the other environment is unaffected).
- Rotate the trust whenever the repository identity changes (rename/transfer → re-verify numeric
  IDs via the preflight `gh-repo-identity` check; they are expected to be stable across renames).

## C. Permitted resource principals (drafted IAM statements)

The statements below are **drafts**: the claim key names available on the exchanged principal
(e.g. `github_environment`) depend on the identity-domain mapping and must be confirmed at the
first live exchange; the variable validation in `infra/bootstrap/variables.tf` requires every
statement to constrain `request.principal`. Statement sets go into
`github_plan_oidc_policy_statements` / `github_apply_oidc_policy_statements` in the operator's
git-ignored `terraform.auto.tfvars`.

**production-plan (plan identity) — reads + state/lock only, no mutation, no state overwrite:**

```text
Allow any-user to inspect compartments in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production-plan'}

Allow any-user to read all-resources in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production-plan'}

Allow any-user to read objects in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production-plan'}
    and target.bucket.name = 'eventforge-tfstate-prod'

Allow any-user to manage objects in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production-plan'}
    and target.bucket.name = 'eventforge-tfstate-prod'
    and target.object.name matches /.*lock.*/i
```

`all {…}` is mandatory here: `any {…}` is an OR and would satisfy the statement on
`request.principal.type = 'workload'` alone, silently dropping the environment constraint. Every
condition below is therefore conjunctive.

`read objects` grants state reads; `manage objects` is restricted to lock objects by
`target.object.name` (OCI supports object-level conditions for object operations; ListObjects is
not restricted by them, which is harmless). **The state object itself is not covered by the manage
statement, so the plan identity cannot overwrite the real production state** — this is the control
that makes the M1B live overwrite-denial test expected to PASS. The exact lock-object suffix must
be confirmed during the disposable backend validation (list the bucket while a lock is held) and
the pattern tightened to it.

**production (apply identity) — EventForge writes + full state access, no tenancy admin:**

```text
Allow any-user to read all-resources in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production'}

# Writes are narrowed to the resource types the platform root actually manages
# (NSGs and their rules, load balancer backends/listeners/certificates,
# monitoring alarms, budgets) — deliberately not manage all-resources. Verify
# each resource-type name against the OCI policy reference during step-8
# review, and confirm the mapped claim key names at the first live exchange.
Allow any-user to manage network-security-groups in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production'}

Allow any-user to manage load-balancers in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production'}

Allow any-user to manage alarms in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production'}

Allow any-user to manage usage-budgets in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production'}

Allow any-user to manage objects in compartment id <compartment_ocid>
  where all {request.principal.type = 'workload',
             request.principal.claims['github_environment'] = 'production'}
    and target.bucket.name = 'eventforge-tfstate-prod'
```

Notes: the apply identity receives write only inside `<compartment_ocid>` (the `Test`
compartment), never tenancy-wide, and no group/user/compartment-management verbs. NSG writes,
load-balancer backends/listeners (ingress-gated), monitoring, budgets, and the Cloudflare-side
resources are all inside this compartment scope. Cloudflare rights are separate: read-only token
in `production-plan`, write token in `production` (same `CLOUDFLARE_API_TOKEN` name).

## D. Negative expectations (live tests after configuration)

Recorded sanitized denials must be observed for: wrong repository, wrong environment, wrong
audience, expired JWT, missing claims, inadequate IAM (plan identity attempting an instance
mutation or a state-object write, apply identity attempting a tenancy-level or IAM change). A
prohibited operation that unexpectedly **succeeds** fails the acceptance gate.
