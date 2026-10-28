# MYSQL-NSG-RETEST — one-attempt procedure (NOT executed)

GATE: MYSQL-NSG-RETEST

> Prepared 2026-10-29 by the B5 execution-preparation mission. This is a
> SEPARATE approval from MYSQL-NSG-IAM and requires that approval to be
> already executed and verified (the policy read-back below is the propagation
> check). Exactly ONE new `UPDATE_DBSYSTEM` attempt is authorized by this
> record; a failure consumes it. The declaration
> `nsg_ids = [oci_core_network_security_group.db.id]` is already merged on
> main (PR #47); the apply runs the dedicated MYSQL-NSG-RETEST gate
> (`scripts/local/m1-platform-apply.sh`, which re-renders the saved plan,
> rechecks it against `platform-safe-plan-mysql-retest-policy.json` at
> attribute level, and re-verifies the live preconditions immediately before
> the one execution). See [../b5-mysql-nsg-diagnosis.md](../b5-mysql-nsg-diagnosis.md).

## Grant

APPROVER: Koka Easwarendra

- Grant phrase: "approved, do both" — operator mission-channel authorization 2026-10-28T22:26Z for (A) the one diagnostics IAM policy create and (B) the one-attempt MySQL NSG retest; no other mutations or retries authorized.
- Timestamp (UTC): 2026-10-28T22:25:46Z
- MYSQL-NSG-IAM execution reference: **EXECUTED 2026-10-28T20:50Z** (single apply, all 25
  gates PASS, evidence `/Users/eswr/secure/evidence/m1local-20261028T205049Z`):
  - `eventforge-mysql-nsg-membership` — ACTIVE,
    `ocid1.policy.oc1..aaaaaaaayjxts754l4i476i345afbcjtiknswm3jlybt3sdl6oycaobzhhga` (Test compartment)
  - `eventforge-mysql-vnic-update` — ACTIVE,
    `ocid1.policy.oc1..aaaaaaaag7mtwjqpgvmzb7rfxiwi4jjsym7ccgqriq5j7b26rghsermuocoq` (tenancy root)
  - Both statements read back character-identical to the reviewed plan; IAM state
    lineage `2d169472-160b-5f38-6141-55cb1bec880a` serial 1, exactly 2 `oci_identity_policy`
    resources; approval [mysql-nsg-iam-approval.md](mysql-nsg-iam-approval.md)
    (APPROVER Koka Easwarendra, plan SHA `c81bbfd3…`).

## Bound plan

- Saved-plan SHA-256: `792989c59339b158086ae6ccbcc51ba76934fab9b9c62829b28af9fb01fabc63`
  (regenerated 2026-10-28 at merged main after PR #48; supersedes `7520337…`,
  which was commit-stale because the apply binds metadata commit = HEAD)
- Source commit: `15f9135832e69ad7ea5e7eb2841fa357bcc05ac7` (merged main, PR #47 + #48)
- Platform state at plan time: lineage `cdda242b-92c1-4371-5b43-495f3849fc4d`, serial 12
- Selected safe-plan policy (recorded in plan metadata):
  `scripts/ci/platform-safe-plan-mysql-retest-policy.json`
- Expected resource diff (verified in the plan JSON): exactly one
  `oci_mysql_mysql_db_system.existing` `update`, `nsg_ids [] →
  [ocid1.networksecuritygroup.oc1.ap-hyderabad-1.aaaaaaaay3iipwy7weycrbdb7slmiu44mmhvnxsrizrrs2w7dpag5wur6hga]`,
  changed leaf paths exactly `nsg_ids`, `after_unknown = {}`, no other
  resource change, no replacement/creation/deletion, no security-list or
  ingress change.
- Plan evidence: `/Users/eswr/secure/evidence/b5prep-retest-post48-20261028T222256Z/`
  (address-level + attribute-level policy PASS at plan time; `applied=false`;
  exactly one `nsg_ids [] → [db-nsg]` update, `after_unknown = {}`)

## Preconditions (all must pass before the attempt)

1. **IAM policies ACTIVE** — `oci iam policy get` for
   `eventforge-mysql-nsg-membership` and `eventforge-mysql-vnic-update` read
   back ACTIVE with statements exactly as reviewed. **VERIFIED 2026-10-28T20:5xZ
   post-apply** (OCIDs above; propagation read-back = the §7 check).
2. Read back MySQL NSG memberships: `oci mysql db-system get --db-system-id
   ocid1.mysqldbsystem.oc1.ap-hyderabad-1.aaaaaaaaes3clz2baohp34kuulobnhrp3cnz33bicso6r4syj7npztnvj2gq`
   → `lifecycle-state = ACTIVE`, `nsg-ids = []`. (**Verified 2026-10-28
   post-apply: ACTIVE, `nsg_ids = []`**; the apply gate re-checks this
   mechanically immediately before execution.)
3. `eventforge-db-nsg` still exists and is AVAILABLE
   (`ocid1.networksecuritygroup.oc1.ap-hyderabad-1.aaaaaaaay3iipwy7weycrbdb7slmiu44mmhvnxsrizrrs2w7dpag5wur6hga`)
   (verified 2026-10-28 post-IAM-apply).
## Connectivity-evidence tiers (required by the 2026-10-28 pre-retest review)

- **CURRENT evidence: NONE.** The workstation public IP rotated
  (`49.207.214.221` → `49.207.216.108`); SSH is `/32`-locked and updating it
  is a network change that is NOT part of any current approval, so the in-VM
  3306 check could not be re-executed.
- **HISTORICAL evidence: 2026-10-28 post-Scope-A** — protocol-level MySQL
  greeting (`26.10.0-cloud`, port 3306) received from BOTH VMs through the
  app subnet ([scope-a-network-execution-approval.md](scope-a-network-execution-approval.md)
  step A3). The path (app subnet → db SL `10.0.2.0/24 → 3306`) is
  configuration-identical today (rule re-verified live, nothing public).
- **NOT YET TESTED:** the NSG-paired path (app-NSG ↔ db-NSG 3306) can only be
  exercised AFTER the retest attaches the db NSG; it is the retest's own
  post-verification step.
- **REQUIRES SEPARATE AUTHORIZATION:** a current in-VM check via OCI Compute
  Run Command — exactly two read-only executions (TCP connect + pre-auth
  greeting, no credentials) — is prepared in
  [vm-mysql-connectivity-diagnostic.md](vm-mysql-connectivity-diagnostic.md).
  If the operator signs that package, its output becomes CURRENT evidence;
  otherwise the historical evidence stands as recorded and this record's
  precondition 4 is accepted (or declined) by the operator at signing.

The retest execution itself has no SSH dependency (it runs over the OCI API
with the pinned Terraform binary).
4. Transitional db security-list rule retained: `rust-api-database-private`
   ingress exactly `10.0.2.0/24 → 3306`, no public 3306 anywhere (verified
   2026-10-28 post-IAM-apply) — the fallback control that keeps the DB
   reachable if the attempt fails.
5. Corrected `m1-verify.sh` shows exactly the two documented MySQL
   state/live findings (`mysql-nsg-state-vs-live` MISMATCH + CRITICAL
   `nsg_ids` drift; budget computed drift acknowledged) with no NEW
   unexpected drift (2026-10-29 baseline: 17 PASS / 2 FAIL, evidence
   `b5prep-verify-20261028T201641Z`).
6. Platform state lineage `cdda242b-92c1-4371-5b43-495f3849fc4d` serial 12 —
   unchanged through the IAM apply (verified post-apply).

## The attempt (exactly one)

Method: `scripts/local/m1-platform-apply.sh <saved .tfplan> <metadata.json> <this record>`
in `infra/platform` with `M1_APPLY_APPROVED_BY` matching the APPROVER line.
The gate refuses a `PLATFORM-APPLY`-marked record, any metadata mismatch, a
remote state move since plan, live MySQL not ACTIVE, or live `nsg_ids` not
equal to the reviewed before-value `[]`. Do NOT use a bare CLI update; the
Terraform path keeps state and config convergent.

## Verification after the attempt

1. The UPDATE_DBSYSTEM work request reaches **SUCCEEDED**
   (`oci mysql work-request get --work-request-id <new-ocid>`). If it FAILS,
   capture `work-request-error list` and STOP — the attempt is consumed; the
   approval-record contract marks the plan applied=FAILED and no retry is
   authorized.
2. `oci mysql db-system get` → `nsg-ids` contains `eventforge-db-nsg`; MySQL
   stays ACTIVE.
3. App→MySQL connectivity from BOTH VMs still passes (now through the
   app-NSG→db-NSG 3306 pairing; the transitional SL rule remains).
4. Corrected `m1-verify.sh`: `mysql-nsg-state-vs-live` now PASSes (state
   records the membership the apply wrote); drift shows no new CRITICAL
   entries; platform lineage unchanged.

## Explicitly out of scope

- **No security-list change.** The db SL's subnet-wide TCP 3306 rule is NOT
  removed or modified by this retest. Tightening it is a separate, later,
  separately reviewed SL-CORRECTION approval (Phase 9 package), only after
  the NSG pairing has an observation window.
- No listener/certificate/backend/DNS/scope-B change; no VM/LB changes; no
  IAM changes beyond the already-executed MYSQL-NSG-IAM set; no state-only
  apply (the 2026-10-29 normal-refresh proof made reconciliation optional,
  not required).
