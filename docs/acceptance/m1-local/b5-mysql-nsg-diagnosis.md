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

Saved plan (commit to be pinned at approval time): **2 to add, 0 to change,
0 to destroy**; plan SHA-256
`d0e1afe65f3cda5e09f45adb4fa93898647ecf686d4878ea53108a864db7c9f2`
(`tfplan.bin`, generated 2026-10-28 at the working tree of `70bc482` + the
new `infra/iam/` root). The dynamic-group alternative was assessed and rejected
(see `infra/iam/main.tf` header comment): the any-user+conditions form is
Oracle-documented verbatim for this exact scenario and is equally binding —
it admits only `mysqldbsystem` principals of DB systems in the Test compartment,
and this tenancy has exactly one DB system. GitHub Stage-2 workload policies
remain disabled and untouched.

**STOP — no IAM apply under this mission.** Executing it requires the written
[MYSQL-NSG-IAM approval](approvals/mysql-nsg-iam-approval.template).

## 6. Retest package (Phase 4) — requires MYSQL-NSG-RETEST approval

A separate one-attempt retest procedure, including the SUCCEEDED verification
and connectivity re-checks, is in
[mysql-nsg-retest-approval.md](mysql-nsg-retest-approval.md). The db security
list's subnet-wide 3306 rule is NOT touched by the retest; removing it is a
[approvals/mysql-nsg-retest-approval.template](approvals/mysql-nsg-retest-approval.template).
The db security list's subnet-wide 3306 rule is NOT touched by the retest;
removing it is a later, separately reviewed network-security change.
