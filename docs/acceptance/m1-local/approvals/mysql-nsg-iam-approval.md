# MYSQL-NSG-IAM — approval record

GATE: MYSQL-NSG-IAM

> Prepared 2026-10-29 by the B5 execution-preparation mission with every
> mechanical binding filled from verified plan evidence
> (`/Users/eswr/secure/evidence/b5prep-iam-plan-20261028T202610Z/`). **Signed
> 2026-10-28T20:50:08Z by the operator in the mission channel** — the
> `SCOPE_DECISION` line and `APPROVER`/grant fields below are the operator's
> own written authorization transcribed verbatim. Creating the two IAM
> policies is the only authorized mutation. Scope context: ACCEPT — Option A
> (tenancy-wide effective scope accepted); this record is the
> mutation-specific written approval that makes that decision executable.
> See [../b5-mysql-nsg-diagnosis.md](../b5-mysql-nsg-diagnosis.md) and
> [mysql-nsg-retest-approval.md](mysql-nsg-retest-approval.md) for the
> separately approved retest.

## Statement-2 effective scope — SCOPE_DECISION machine-validated (blocker)

> Verified against Oracle's policy-inheritance documentation
> ([Identity/Concepts/policies.htm](https://docs.oracle.com/en-us/iaas/Content/Identity/Concepts/policies.htm),
> 2026-10-28; see [../b5-mysql-nsg-diagnosis.md](../b5-mysql-nsg-diagnosis.md)
> §8): a location clause naming a compartment covers that compartment AND all
> descendants, so `eventforge-mysql-vnic-update` — attached at the tenancy
> with `in compartment id <tenancy-OCID>` — is **effectively TENANCY-WIDE**,
> not root-only. No documented policy-language form scopes a grant to the
> root compartment only. The where-clause (mysqldbsystem principals of DB
> systems in Test; exactly one DB system) is the binding limit. Practical
> delta: the MySQL service principal could in principle associate/disassociate
> NSG memberships on the Test-compartment VNICs (two API VMs, load balancer).

**Execution is REFUSED while the placeholder below remains. The operator
must deliberately replace that placeholder line — in place, keeping it the
record's ONLY line carrying the `SCOPE_DECISION` marker, standalone at top
level — with the marker, a colon, one space, and exactly `ACCEPT_TENANCY_WIDE_VNIC`:**

```
SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC
```

`scripts/local/m1-iam-apply.sh` validates this mechanically in its offline
section, before any live access, and refuses: a missing line, the untouched
placeholder, `ORACLE_FIRST`, `DECLINED`, multiple or conflicting decisions, a
decision quoted inside this commentary, or trailing text on the line. An
untouched copy authorizes nothing. Nothing else (commentary, environment
variables, a passing policy check) can grant this acceptance.

## Grant

APPROVER: Koka Easwarendra

- Grant phrase (verbatim, operator message 2026-10-28T20:50:08Z): "I authorize one guarded Terraform apply of saved plan SHA-256 c81bbfd3080ae9a2117bb2e546c780511fbe545c4a164c2783a89442e9ccb239, generated from commit 9a0724f59394839f8fa5b213c8e189f4270c74de, creating only oci_identity_policy.mysql_nsg_membership and oci_identity_policy.mysql_vnic_update. I acknowledge the effectively tenancy-wide VNIC permission scope for qualifying MySQL resource principals. No other mutations or retries are authorized."
- Timestamp (UTC): `2026-10-28T20:50:08Z`
- Source commit (must be the full merged main commit containing
  `infra/iam/`): `9a0724f59394839f8fa5b213c8e189f4270c74de`

## Bound mutation

- Root: `infra/iam` — plan **2 to add, 0 to change, 0 to destroy** (verified
  in the saved plan JSON: exactly two `create` actions, nothing else)
- Saved-plan SHA-256: `c81bbfd3080ae9a2117bb2e546c780511fbe545c4a164c2783a89442e9ccb239`
  (generated at the pinned commit by `m1-iam-plan.sh`, metadata
  `applied=false`, contract checker PASS; evidence
  `/Users/eswr/secure/evidence/b5prep-iam-plan-20261028T202610Z/`)
- Expected initial state: iam/terraform.tfstate absent (fresh root; absence
  re-proven 2026-10-29 via list-object-versions, `m1_prove_state_key_absent`;
  the apply refuses if the key exists)
- Resources created (exactly these two addresses, no others):
  - `oci_identity_policy.mysql_nsg_membership` (compartment: Test,
    `ocid1.compartment.oc1..aaaaaaaar3kvayxcj4vuo6ydkoaxrh4yeovnvr6rgxr7kdljzijrpbxaz3ea`)
  - `oci_identity_policy.mysql_vnic_update` (compartment: tenancy root,
    `ocid1.tenancy.oc1..aaaaaaaazzqo7xp5qax5ebj375o7qgnpyhxfxwrfq5e3ldjoxngx7nouwtsq`)
- Complete policy statements (verbatim from the saved plan; the apply verifies
  these strings character-for-character against the rendered contract
  `scripts/ci/iam-plan-contract.json`):
  - Statement 1: `Allow any-user to {NETWORK_SECURITY_GROUP_UPDATE_MEMBERS} in compartment id ocid1.compartment.oc1..aaaaaaaar3kvayxcj4vuo6ydkoaxrh4yeovnvr6rgxr7kdljzijrpbxaz3ea where all {request.principal.type='mysqldbsystem', request.resource.compartment.id='ocid1.compartment.oc1..aaaaaaaar3kvayxcj4vuo6ydkoaxrh4yeovnvr6rgxr7kdljzijrpbxaz3ea'}`
  - Statement 2: `Allow any-user to {VNIC_CREATE, VNIC_UPDATE, VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP, VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP} in compartment id ocid1.tenancy.oc1..aaaaaaaazzqo7xp5qax5ebj375o7qgnpyhxfxwrfq5e3ldjoxngx7nouwtsq where all {request.principal.type='mysqldbsystem', request.resource.compartment.id='ocid1.compartment.oc1..aaaaaaaar3kvayxcj4vuo6ydkoaxrh4yeovnvr6rgxr7kdljzijrpbxaz3ea'}`

## Preconditions (verified 2026-10-29 before this record)

1. Fresh plan at commit `9a0724f…` passes the IAM contract checker (statements
   and compartments exactly as in `infra/iam/main.tf`; no other resource
   changes) — PASS.
2. Corrected `m1-verify.sh` result 17 PASS / 2 FAIL, where the 2 FAILs are the
   documented, expected MySQL state/live discrepancy and its CRITICAL drift
   classification (evidence `b5prep-verify-20261028T201641Z`); the historical
   18/0 bar does not apply while that discrepancy stands.
3. MySQL DB system `rust-api-heatwave` is ACTIVE with live `nsg_ids = []` — PASS.

## Stop conditions

- Plan shows any resource besides the two policies, any change/destroy, or any
  statement differing from the reviewed text → STOP.
- Policy-create API error (e.g., syntax rejection of
  `in compartment id <tenancy-ocid>`) → STOP; no fallback location without a
  new approval (../b5-mysql-nsg-diagnosis.md §8).
- Anything else unexpected → STOP, preserve logs; a failed apply consumes
  this approval record.

## Explicitly not authorized by this approval

MySQL NSG retry (separate `GATE: MYSQL-NSG-RETEST` approval), security-list
changes, Terraform applies in other roots, GitHub Stage-2 workload policies,
federation changes, scope B. A successful apply does NOT resolve B5 by itself
and does NOT authorize the retest.
