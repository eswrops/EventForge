# B5 — MySQL DB-NSG attachment: failure diagnosis (2026-10-28)

Status: diagnosis complete, read-only. **No OCI change was made.** Companion
packages (both requiring separate operator approvals, neither executed):
[approvals/mysql-nsg-iam-approval.template](approvals/mysql-nsg-iam-approval.template)
(IAM) and [approvals/mysql-nsg-retest-approval.template](approvals/mysql-nsg-retest-approval.template) (retest).

## 1. Headline finding — reclassification of B5

The Scope-A execution record initially characterized the failure as a
"service-side limitation on `MySQL.Free`". **That characterization is wrong.**
The failed work requests expose the actual cause:

> **Error code `AuthorizationFailed`** — "Authorization failed or requested
> resource not found. Please ensure that resource exists and you have all the
> required IAM policies in place. See
> https://docs.oracle.com/en-us/iaas/mysql-database/doc/iam-policies.html."

followed by:

> **Error code `DbSystemUpdateEndpointFailure`** — "The DB System Endpoint
> update failed. To avoid access inconsistencies in between different endpoints
> on the DB System, please retry the operation."

This is a **missing IAM policy** failure, not a `MySQL.Free` shape limitation.
No Oracle evidence supports a Free-tier NSG restriction; the `AuthorizationFailed`
code is explicit. Classification per the review rubric:
**CONFIRMED_MISSING_PERMISSION** (§4).

## 2. Failed work requests (Phase 1)

Both UPDATE_DBSYSTEM work requests — the Terraform-provider update and the
direct CLI retry — failed identically:

| Field | Terraform-driven (provider) | CLI retry |
| --- | --- | --- |
| Work-request OCID | `ocid1.mysqlworkrequest.oc1.ap-hyderabad-1.amaaaaaatiosumia6adq6dmolscekutw4h7bznhlsbp5waz7so4d46xugqga` | `ocid1.mysqlworkrequest.oc1.ap-hyderabad-1.amaaaaaatiosumiawn4uvkjz7vxamoj7pqsg6ur7wgteg7vgd7cxrgse5iqq` |
| Operation | `UPDATE_DBSYSTEM` | `UPDATE_DBSYSTEM` |
| Accepted | 2026-10-27T19:46:54.5Z | 2026-10-27T19:49:24.5Z |
| Started | (audit `.begin` 19:46:54.5Z) | 2026-10-27T19:49:37.8Z |
| Finished | 2026-10-27T19:47:41.9Z | 2026-10-27T19:50:21.8Z |
| Status | **FAILED** (percent 100) | **FAILED** (percent 100) |
| Errors | `AuthorizationFailed` (19:47:32.774Z), then `DbSystemUpdateEndpointFailure` (19:47:41.844Z) | `AuthorizationFailed` (19:50:10.622Z), then `DbSystemUpdateEndpointFailure` (19:50:21.781Z) |
| Resource | `rust-api-heatwave` (`ocid1.mysqldbsystem.oc1.ap-hyderabad-1.aaaaaaaaes3clz2baohp34kuulobnhrp3cnz33bicso6r4syj7npztnvj2gq`) | same |

Request IDs captured: the API-key user's `UpdateDbSystem` calls carried
`opc-request-id` `adb82298eba55d0cb93e5169e0ab31e4/C36608CFC7B581DEADFFE06A4859444A/5EADD7021A32E54BF93D1BE720977ABD`
(Terraform) and `97501839889549C28068F366C2693479/0F4BD7FA7B9867D94300E16A4859449C/EFC4FE7A4CD912F4C1FB08013981E867`
(CLI); the later `list_work_request_logs` attempts (which return 404
`NotAuthorizedOrNotFound` for this principal on both attempts —
`F5690337FFF34600800B29216D10AA96/8ECC5930EBDCB166C006E16A485944B9/05150D7E072A2D60446D01CDEC482748`
and `698C19570FB14F308199F51DAA7445E1/9FE855557D79ACEACE06E16A48594470/2FF2D72483D56F552ED88480857FC00F`)
are a secondary symptom of the same missing-policy situation and do not hide
the errors, which are complete in `work-request-error list`.

**Audit correlation** (compartment `Test`, window 19:45–19:56Z 2026-10-27): both
`com.oraclecloud.Mysqlaas.UpdateDbSystem.begin` events returned `204` to the
API-key principal (Koka Easwarendra, `Administrators` — the accepting API call
was fully authorized), and both `…UpdateDbSystem.end` events recorded status
**500** with no principal name — the failure happened **inside the work
request**, after the MySQL service took over. The DB system stayed `ACTIVE`
throughout (`lifecycleState=ACTIVE` in both `.end` events).

**Console cross-check:** the Console Work-Request Messages page was not used;
the CLI `work-request-error list` output is complete (two error entries each),
so nothing is missing.

Sanitized evidence (0600, outside the repository):
`/Users/eswr/secure/evidence/m1local-b5-diagnosis-20261027T201834Z/` —
`wr-{cli,tf}-get.json`, `wr-{cli,tf}-errors.json`, `wr-cli-log-listing-fail.json`,
`dbsystem-now.json` (nsg-ids `[]`, ACTIVE), `audit-updatedbsystem-window.json`,
`iam-plan/` (the corrective IAM saved plan, §5).

## 3. Compartment layout (why the grant must cross a boundary)

| Resource | Compartment |
| --- | --- |
| MySQL DB system `rust-api-heatwave` | **Test** |
| `eventforge-db-nsg` (and app/lb NSGs) | **Test** |
| MySQL subnet `rust-api-db-private-subnet` (10.0.3.0/24) and the DB system's endpoint **VNIC** | **tenancy root** |

When the DB system updates its NSGs, the MySQL service acts as the DB system's
resource principal (`mysqldbsystem`) and must (a) update membership on the NSG
in **Test** and (b) update the VNIC in the **root** compartment. Permissions
granted in the Test compartment do NOT cover the root-compartment VNIC — the
two grants must exist separately, in the compartment that owns the target
resource.

## 4. IAM requirements vs. inventory (Phase 2)

Oracle documents the mandatory resource-principal policies for DB-system NSG
updates (mysql-database/doc/mandatory-policies-permissions.html and
mysql-database/doc/resource-principals.html), verbatim requirements:

1. `NETWORK_SECURITY_GROUP_UPDATE_MEMBERS` — in the **NSG's** compartment
2. `VNIC_CREATE, VNIC_UPDATE, VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP,
   VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP` — in the **subnet's** compartment

both restricted to principals where
`request.principal.type='mysqldbsystem'` and
`request.resource.compartment.id = <DB-system compartment>`.

Existing tenancy IAM inventory (read-only, 2026-10-28):

| Policy (compartment) | Statements | Covers mysqldbsystem? |
| --- | --- | --- |
| `Tenant Admin Policy` (tenancy) | `ALLOW GROUP Administrators to manage all-resources IN TENANCY` | No — group-based, human principals only |
| `eventforge-instance-backups` (tenancy) | dynamic-group `eventforge-instances` → objects/buckets in Test (backups bucket) | No |
| `eventforge-objectstorage-kms` (tenancy) | objectstorage service → tfstate bucket + CMK key | No |
| (Test compartment) | **no policies at all** | — |
| Dynamic groups | `eventforge-instances` (the two compute instances only) | — |

Gap analysis: **both** documented resource-principal statements are absent —
CONFIRMED_MISSING_PERMISSION. No other error class is implicated: the operator
user could read and update the DB system (Audit 200/204), the NSG exists and is
AVAILABLE, and the DB system is ACTIVE — only the service-internal principal is
denied. `MySQL.Free` limitation: **not confirmed** (SERVICE_LIMITATION_CONFIRMED
is explicitly NOT supported by any evidence found).

## 5. Corrective package (Phase 3) — requires MYSQL-NSG-IAM approval

`infra/iam/` (new root, separate state key `iam/terraform.tfstate` in the
existing CMK-bound bucket; no bootstrap/platform changes) creates exactly two
policies:

- `eventforge-mysql-nsg-membership` (attached in Test): `Allow any-user to
  {NETWORK_SECURITY_GROUP_UPDATE_MEMBERS} in compartment id <Test> where all
  {request.principal.type='mysqldbsystem', request.resource.compartment.id='<Test>'}`
- `eventforge-mysql-vnic-update` (attached at tenancy): `Allow any-user to
  {VNIC_CREATE, VNIC_UPDATE, VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP,
  VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP} in compartment id <tenancy-root>
  where all {request.principal.type='mysqldbsystem',
  request.resource.compartment.id='<Test>'}`

Saved plan: **2 to add, 0 to change, 0 to destroy**, regenerated at the
merged revision carrying the execution-safety contracts (see §7; the
historical 2026-10-28 plan at working tree `70bc482` + new `infra/iam/` had
SHA-256 `d0e1afe65f3cda5e09f45adb4fa93898647ecf686d4878ea53108a864db7c9f2`
and is superseded — the approval binds the plan generated at the pinned
merged commit via the guarded `m1-iam-plan.sh` flow). Both policy resources
now carry `lifecycle { prevent_destroy = true }`. The dynamic-group
alternative was assessed and rejected
(see `infra/iam/main.tf` header comment): the any-user+conditions form is
Oracle-documented verbatim for this exact scenario and is equally binding —
it admits only `mysqldbsystem` principals of DB systems in the Test compartment,
and this tenancy has exactly one DB system. GitHub Stage-2 workload policies
remain disabled and untouched.

**STOP — no IAM apply under this mission.** Executing it requires the written
[MYSQL-NSG-IAM approval](approvals/mysql-nsg-iam-approval.template).

## 6. Retest package (Phase 4) — requires MYSQL-NSG-RETEST approval

A separate one-attempt retest procedure, including the SUCCEEDED verification
and connectivity re-checks, is bound by the
[MYSQL-NSG-RETEST approval template](approvals/mysql-nsg-retest-approval.template);
its plan is guarded by the dedicated attribute-level policy
`scripts/ci/platform-safe-plan-mysql-retest-policy.json` (exactly
`oci_mysql_mysql_db_system.existing`, update, `nsg_ids` only, `[]` →
`eventforge-db-nsg`; fixtures in `tests/ci/test-safe-plan-mysql-retest.sh`).
The db security list's subnet-wide 3306 rule is NOT touched by the retest;
removing it is a later, separately reviewed network-security change.

## 7. Execution-safety contracts (2026-10-28, prepared — nothing applied)

**The IAM package is PREPARED, NOT APPLIED.** As of this revision no
`eventforge-mysql-*` policy exists in the tenancy (verified read-only) and the
`iam/terraform.tfstate` key has never held state. Execution requires the
written MYSQL-NSG-IAM approval and is tool-guarded end to end:
`scripts/local/m1-iam-{init,plan,apply}.sh` (pinned Terraform 1.12.2, APIKey
profile `DEFAULT`, exact backend coordinates, default workspace, locking
retained, no migration/recovery/auto-approve/retry, evidence outside the
repository) with the exact two-policy contract checker
`scripts/ci/assert-iam-plan.sh` + `scripts/ci/iam-plan-contract.json`.
State-key absence is PROVEN fail-closed (`m1_prove_state_key_absent`):
authorization failures, service errors, unparseable listings, historical
object versions, and delete markers for `iam/terraform.tfstate` all STOP the
guard — absence is never inferred from an error. The apply additionally
re-renders the SHA-bound saved plan and re-runs the contract checker on it
immediately before execution (`offline-contract-recheck`). Reconciliation of
the state key (read-only, 2026-10-28): no `iam/terraform.tfstate` object or
version has ever existed; the only `iam/` history is four DELETED
`iam/terraform.tfstate.lock` versions (two clean acquire/release cycles,
2026-10-27T20:27Z, from the earlier plan-generation session) — benign
Terraform locking residue, no live lock, ownership unambiguous.

- **The `AuthorizationFailed` error code strongly supports the
  missing-permission diagnosis**: the accepting `UpdateDbSystem` API calls
  returned 204 to the fully authorized operator principal, and both failures
  happened inside the service-side work request — the classic signature of the
  service's resource principal lacking policies. It is not, by itself, a
  cryptographic proof (a transitory service-side authorization regression
  would look similar), which is why the corrective policies remain gated on
  operator approval rather than auto-executed.
- **The MySQL retry remains independently gated.** MYSQL-NSG-IAM execution
  does NOT authorize the retest: [MYSQL-NSG-RETEST](approvals/mysql-nsg-retest-approval.template)
  is a separate approval with its own preconditions and exactly one attempt.
- **A successful IAM apply does not by itself make B5 PASS.** B5 moves to
  resolved only when the separately approved retest shows the new
  `UPDATE_DBSYSTEM` work request SUCCEEDED, `nsg_ids` containing
  `eventforge-db-nsg`, and connectivity intact from both VMs. Until then B5
  stands (DB system ACTIVE, `nsg_ids = []`, effective posture governed by the
  db security list).
- **IAM policy propagation may need verification before the retry.** Newly
  created policies are usually effective within seconds but Oracle documents
  no strict propagation bound; the retest preconditions already require
  reading both policies back (`oci iam policy get`) with statements exactly
  as reviewed — if the read-back or an execution-time validation fails,
  STOP and re-approve; the one retest attempt is not to be spent on a
  possibly-unpropagated grant.

## 8. Tenancy-root policy location — question and final determination (2026-10-28, corrected post-#42)

**Question.** Statement 2 attaches at the tenancy using
`in compartment id <tenancy-OCID>`. Is that grant scoped to the ROOT
compartment only?

**Authoritative finding.** PR #42 initially judged the form the "narrowest
reading" pinning the grant to exactly one compartment. **That was wrong.**
Oracle's policy documentation
([Identity/Concepts/policies.htm](https://docs.oracle.com/en-us/iaas/Content/Identity/Concepts/policies.htm),
"Policy inheritance", retrieved verbatim 2026-10-28) states:

> "Compartments inherit any policies from their parent compartment. …
> Policies that apply to resources in CompartmentA also apply to resources in
> CompartmentB and CompartmentC. So this policy:
> `Allow group NetworkAdmins to manage virtual-network-family in compartment CompartmentA`
> allows the group NetworkAdmins to manage VCNs in CompartmentA,
> CompartmentB, and CompartmentC."

A location clause naming a compartment therefore covers that compartment AND
all its descendants. Every compartment in the tenancy descends from root, so
`in compartment id <tenancy-OCID>` attached at the tenancy is **effectively
tenancy-wide** — functionally equivalent in resource coverage to `in tenancy`.
The documented policy language provides **no root-only form**.

**Determination: root-only access CANNOT be established — the MYSQL-NSG-IAM
approval blocker is RETAINED.** Effective scope of statement 2 if executed:
`VNIC_CREATE, VNIC_UPDATE, VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP,
VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP` on VNICs in **all** compartments,
for principals satisfying the where-clause (mysqldbsystem resource principals
of DB systems in Test — this tenancy has exactly one, `rust-api-heatwave`).
The practical delta versus a hypothetical root-only grant is the
Test-compartment VNICs (the two API VM primary VNICs, the load balancer's
VNICs): the MySQL service principal could in principle associate/disassociate
their NSG memberships. The binding limits are the subject/origin where-clause
constraints, not the location clause. The statements themselves remain the
Oracle-documented mandatory minimum — they are NOT broadened deliberately;
only the documentation of their effective scope is corrected here.

**Outstanding operator decision (blocks MYSQL-NSG-IAM):**
1. **Accept the tenancy-wide effective scope** of the Oracle-mandated
   statement (recommended reading of the evidence: the where-clause admits
   only the single Test DB-system principal; VNIC verbs are narrow; no
   narrower documented form exists), acknowledge it in the approval record,
   and execute. OR
2. **Seek Oracle confirmation first** that `target.compartment.id` (or
   another documented condition variable) reliably constrains VNIC targets
   for mysqldbsystem principals, enabling a genuinely narrower where-clause —
   this would be a NEW reviewed statement, not a variant of this package. OR
3. Do not execute; B5 remains blocked (db security list 3306 stays the
   governing control — effective posture unchanged and closed).

Until the operator's written decision is recorded, the approval template's
acknowledgment block is unfilled and execution remains REFUSED. The
former stop condition about a create-time syntax rejection of
`in compartment id <tenancy-OCID>` is retained (any service-side rejection →
STOP, preserve logs, no fallback without a new approval).

## 9. `target.compartment.id` applicability investigation (2026-10-28)

**Question.** Can `target.compartment.id` reliably constrain the four VNIC
permissions in statement 2 (`VNIC_CREATE`, `VNIC_UPDATE`,
`VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP`,
`VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP`) to the root compartment for
service-initiated operations by `mysqldbsystem` principals — enabling a
genuinely narrower where-clause than the accepted tenancy-wide scope?

**Documented facts** (all retrieved verbatim 2026-10-28):

1. **Definition** — Policy Reference, "General Variables for All Requests"
   ([Identity/Reference/policyreference.htm](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/policyreference.htm)):
   `target.compartment.id` (Entity/OCID) is "The OCID of the compartment
   containing the primary resource", with a note that it cannot be used with
   List operations to filter by the requesting user's compartment access.
2. **Undefined-variable semantics** — Advanced Policy Features
   ([Identity/Concepts/policyadvancedfeatures.htm](https://docs.oracle.com/en-us/iaas/Content/Identity/Concepts/policyadvancedfeatures.htm),
   "Variables that Aren't Applicable to a Request Result in a Declined
   Request"): "If the variable is not applicable to the incoming request, the
   condition evaluates to false and the request is declined." Adding a
   `target.compartment.id` condition can therefore only ever NARROW or BREAK
   a grant — never broaden it.
3. **MySQL's own mandatory-policy documentation** — Resource Principals
   ([mysql-database/doc/resource-principals.html](https://docs.oracle.com/en-us/iaas/mysql-database/doc/resource-principals.html),
   "Defining a Policy for Network Security Groups", current © 2026 page)
   documents the any-user form verbatim with ONLY
   `request.principal.type='mysqldbsystem'` and
   `request.resource.compartment.id='<DB-system compartment>'` conditions.
   `target.compartment.id` appears NOWHERE in the MySQL Database policy
   documentation.
4. **Core Services details** — the
   [Details for the Core Services](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/corepolicyreference.htm)
   `vnics` verb/permission table confirms the four permissions map to the
   VNIC APIs, but the Core Services "Supported Variables" section lists only
   `target.boot-volume.kms-key.id` and `target.image.id` as service-specific
   target variables and says nothing about variable population for
   service-initiated (resource-principal) request flows.

**Per-operation assessment.** For user-initiated API calls the definition
above implies `target.compartment.id` would hold the compartment of the VNIC
(primary resource). For the mysqldbsystem service-initiated flow, NO Oracle
documentation states whether the variable is populated at all, and the
"primary resource" is ambiguous for the cross-resource pair:

| Permission | Primary resource if populated | Documented for mysqldbsystem service-initiated flow? |
| --- | --- | --- |
| `VNIC_CREATE` | the new VNIC (subnet's compartment = root) | No |
| `VNIC_UPDATE` | the endpoint VNIC (root) | No |
| `VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP` | ambiguous — VNIC (root) vs NSG (Test) | No |
| `VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP` | ambiguous — same pair | No |

**Determination: NOT USABLE on documentation alone.** Outcome matrix if
`target.compartment.id='<root-OCID>'` were added to statement 2: (a) populated
with the VNIC compartment → grant genuinely narrows to root (desired
semantics); (b) not populated → condition evaluates false → EVERY VNIC
operation declined → the retest fails with the identical `AuthorizationFailed`
symptom, wasting the single retest attempt (fail-closed, no security
regression, but operational breakage); (c) populated with the NSG compartment
for the associate/disassociate pair → condition denies (root ≠ Test). The
variable does not have a confirmed, identical meaning across the four verbs
in this flow. A live test would require creating a production-shaped IAM
policy, which is not authorized.

**Draft Oracle support question** (prepared, NOT filed; no test policy to be
created):

> **Subject:** Is `target.compartment.id` populated for service-initiated VNIC
> operations by `mysqldbsystem` resource principals (DB-system NSG update flow)?
>
> **Context:** Tenancy `<tenancy-OCID>`, region ap-hyderabad-1. A MySQL DB
> system lives in compartment "Test"; its subnet and endpoint VNIC live in the
> tenancy root compartment. Updating the DB system's network security groups
> requires resource-principal permissions per
> [Resource Principals (MySQL Database)](https://docs.oracle.com/en-us/iaas/mysql-database/doc/resource-principals.html),
> "Defining a Policy for Network Security Groups".
>
> 1. For each of `VNIC_CREATE`, `VNIC_UPDATE`,
>    `VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP`,
>    `VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP`, as exercised by the
>    DB-system NSG update work request (service-initiated by the
>    `mysqldbsystem` resource principal): is the policy condition variable
>    `target.compartment.id` populated, and if so, with the compartment of
>    which resource (the VNIC, the NSG, or the DB system)?
> 2. Which resource is the "primary resource" for
>    `VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP` /
>    `VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP` in this flow — the VNIC or
>    the NSG?
> 3. If `target.compartment.id` is not populated for any of these
>    service-initiated operations, please confirm that a where-clause using
>    it declines the operation, per "Variables that Aren't Applicable to a
>    Request Result in a Declined Request" (Advanced Policy Features).
> 4. Does Oracle document or support any policy-language form that scopes
>    these VNIC permissions to the ROOT compartment only for `mysqldbsystem`
>    principals, given that a location clause naming a compartment also
>    covers all descendant compartments via policy inheritance?
>
> If confirmed populated and stable for all four permissions, we intend to
> add `target.compartment.id = '<root-compartment-OCID>'` to the where-clause
> of our VNIC statement as a NEW reviewed change. We will not create test
> policies pending your answer.

## 10. Security-scope options A/B/C (2026-10-28, decision aid for MYSQL-NSG-IAM)

| | **OPTION A — execute reviewed policies** (tenancy-wide effective scope, explicitly accepted) | **OPTION B — root-target-restricted policy** (only if §9 semantics are confirmed) | **OPTION C — no additional IAM policy** |
| --- | --- | --- | --- |
| Content | The two reviewed policies of §5, exactly as Oracle's Resource Principals doc prescribes | Statement 2 + `target.compartment.id='<root-OCID>'` in the where-clause — a NEW reviewed package | Nothing; B5 stays blocked |
| Blast radius | Four narrow VNIC verbs + one NSG-membership verb, tenancy-wide by inheritance, for principals satisfying the where-clause (mysqldbsystem principals of Test DB systems — this tenancy has exactly one). Practical delta beyond root: the same principal could in principle associate/disassociate NSGs on the two Test API-VM VNICs and the LB VNICs | Strictly smaller: VNIC verbs only on root-compartment VNICs — IF the variable is populated for all four service-initiated verbs (unconfirmed, §9) | Zero new IAM grants |
| Operational consequences | Matches the Oracle-documented mandatory minimum verbatim → highest probability the single retest attempt succeeds; no dependence on undocumented variable behavior | If the variable is unpopulated or ambiguous (§9 matrix), the retest fails with the identical `AuthorizationFailed` symptom — one retest attempt burned, diagnosis cost, support burden on an undocumented combination | MySQL NSG segmentation remains unavailable; the db security list's subnet-wide 3306 rule stays the governing (weaker, subnet-wide) control; B5 unresolved and gating |
| Reversibility | Policies carry `prevent_destroy`; narrowing later (e.g., after an Oracle answer enables Option B) is a separately reviewed statement update | Same mechanism | Nothing to reverse, but the control gap remains open indefinitely |
| Status | READY — requires the machine-enforced `SCOPE_DECISION: ACCEPT_TENANCY_WIDE_VNIC` line in the approval record | NOT AVAILABLE — documentation inconclusive (§9); would need Oracle confirmation + new review | Status quo |

**Recommendation.** Option A is the least-privilege policy that is actually
EXECUTABLE today: it is the Oracle-documented mandatory minimum, doubly
constrained by the where-clause, and its tenancy-wide effective scope is now
an explicit, machine-validated operator acceptance rather than an implicit
side effect. Option B would be strictly narrower but is unverifiable without
an Oracle answer and risks burning the one retest attempt on an undocumented
condition. Option C is the most conservative in IAM terms but leaves the
intended NSG-based 3306 control unrealized and the db security list's
subnet-wide rule in force.
