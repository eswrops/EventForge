# M1-LOCAL blockers and deferred items

## Active blockers

| # | Blocker | Impact | Path forward |
| --- | --- | --- | --- |
| B1 | ~~OCI-IMPORT approval~~ **RESOLVED 2026-10-27** — imports executed under the written approval record; 8/8 verified, reconciliation clean | — | [imports.md](imports.md) §6 |
| B2 | ~~PLATFORM-APPLY approval~~ **RESOLVED 2026-10-27** — two SHA-bound apply rounds completed the 29-create set (budget compartment fix documented); live verification 18/0 | — | [platform-plan.md](platform-plan.md) §6 |
| B3 | **ONS email subscription PENDING** (verified live again 2026-10-28 post-Scope-A: `eswr.ops@gmail.com`, topic `eventforge-operations` (ACTIVE), Test compartment, lifecycle-state `PENDING`) | Alarm notifications cannot be marked delivered; alarm delivery is not PASS until the confirmation email is clicked and verified | **Operator confirmation action:** click the confirmation email (sent 2026-10-27T06:07Z) or resend it via `oci ons subscription resend-confirmation --subscription-id <ocid>`, then re-verify lifecycle-state = ACTIVE. No test notification is sent without separate approval |
| B4 | ~~Operator inputs for planning~~ **OBSOLETE** — the gated apply required no Cloudflare API access (`enable_api_ingress=false`; zero Cloudflare resources). Real account_id/zone_id/root_domain/token become mandatory only for the future ingress-enablement gate | Deferred to ingress enablement | operator supplies at that gate |

## Scope A outcome status (2026-10-28)

| Item | Status |
| --- | --- |
| Scope A successful changes (app NSG ×2 VNICs, lb NSG, SL corrections) | **PASS** (verified live; [security.md](security.md)) |
| MySQL DB-NSG attachment | **BLOCKED** (B5 — missing IAM resource-principal policies; [b5-mysql-nsg-diagnosis.md](b5-mysql-nsg-diagnosis.md)) |
| MySQL connectivity (app VMs → 10.0.3.18:3306, protocol greeting) | **PROTOCOL_LEVEL_PASS** |
| Authenticated database login | **NOT_VERIFIED** (admin username held only in the operator vault; [imports.md](imports.md) §6) |
| ONS delivery | **PENDING** (B3) |
| Scope B (listener/certificate/backends/DNS/Cloudflare) | **NOT_AUTHORIZED** |

## Deferred (unchanged from full M1 — do not mark PASS here)

| Item | Status | Owner of the gate |
| --- | --- | --- |
| OCI-FEDERATION (JWT→RPST exchange) | **DEFERRED** — Oracle SR required to enable workload-identity exchange on the DEFAULT domain (ap-hyderabad-1); clients `eventforge-github-plan`/`-apply` + trust `eventforge-github` remain CREATED and untouched | [../m1-final/workload-federation.md](../m1-final/workload-federation.md) §0 |
| GitHub Stage-2 IAM policies | **DEFERRED** — behind the first successful live exchange + recorded claim mapping | federation §3; `enable_workload_policies=false` |
| IAM-DENIAL probe | **NOT_RUN** — requires an underprivileged principal; refuses `DEFAULT` by design | federation §5 |
| GitHub-dependent release installer as production path | **PREPARED, not local-tested** — local release installation is a separate later mechanism; application deployment is NOT claimed by M1-LOCAL | [../m1-final/release-operations.md](../m1-final/release-operations.md) |
| NSG attachment to existing VM VNICs / LB / MySQL | **VM VNICs + LB: DONE 2026-10-28** (Scope-A apply, verified live — [security.md](security.md)); **MySQL: BLOCKED** at the service level (B5 below) — the db SL remains the governing 3306 control | — |
| ~~Live app security list pins SSH source `49.207.205.137/32`~~ **RESOLVED 2026-10-28** — Scope-A app-SL correction reconciled the source to the reviewed `49.207.214.221/32`; real SSH to both VMs verified | — | [security.md](security.md) |
| B5 | **MySQL DB-NSG attachment BLOCKED — missing IAM resource-principal policies** (2026-10-28, Scope-A execution; **re-diagnosed same day**, [b5-mysql-nsg-diagnosis.md](b5-mysql-nsg-diagnosis.md)): both `UPDATE_DBSYSTEM` work requests (Terraform-provider AND direct CLI) FAILED with `AuthorizationFailed` + `DbSystemUpdateEndpointFailure` — the `mysqldbsystem` resource principal has no policies for NSG membership updates (Test compartment) or endpoint-VNIC updates (subnet lives in the tenancy ROOT compartment). The earlier "service-level limitation on `MySQL.Free`" characterization was **wrong** and is retracted. The DB system remains ACTIVE and unaffected (`nsg_ids = []`) | The intended app-NSG↔db-NSG 3306 pairing cannot complete; the db security list's subnet-wide 3306 rule (retained as the explicit transitional control) remains the governing restriction — effective posture is unchanged and closed | Two separately approved steps: (1) execute the minimal corrective IAM package `infra/iam` under a written [MYSQL-NSG-IAM approval](approvals/mysql-nsg-iam-approval.template); (2) one-attempt retest under [MYSQL-NSG-RETEST](approvals/mysql-nsg-retest-approval.template); only after an observation window, tighten the db SL (separate SL-CORRECTION approval). No Oracle SR is required by the current evidence |
| M2 | **NOT_STARTED** (rule 16) | — |

## Operational follow-ups (recorded 2026-10-28 — none are acceptance failures)

These are operational follow-ups, not evidence that the successful M1-LOCAL infrastructure
apply failed:

| # | Follow-up | Detail |
| --- | --- | --- |
| O1 | Actual OCI billed cost remains unverified | Read-only CLI cannot read cost/usage summaries without creating a saved query (a tenancy write, not authorized); the $5 budget + 3 alert rules are the runtime tripwire ([cost.md](cost.md)) |
| O2 | E2.1.Micro free quota is fully consumed | `standard-e2-micro-core-count` AD-1: available=0, used=2 — the two running VMs occupy the entire free allocation ([cost.md](cost.md)) |
| O3 | GitHub WIF deferred pending Oracle investigation | JWT→RPST exchange blocked on Oracle SR; clients + trust created and dormant ([../m1-final/workload-federation.md](../m1-final/workload-federation.md)) |
| O4 | Local Terraform deployment remains available | `scripts/local/` guard library, pinned Terraform 1.12.2, API-key profile `DEFAULT`; plan/verify re-run clean 2026-10-28 post-Scope-A (18 PASS / 0 FAIL, plan changes=0, serial **12**) |
| O5 | Application release artifacts are not yet deployed | M1-LOCAL claims infrastructure only; no binary/artifact deployment was performed ([../m1-final/release-operations.md](../m1-final/release-operations.md)) |
| O6 | Frontend Worker publication is not complete | `infra/frontend` root exists; no Worker was published by this track (explicitly out of scope) |

## Historical evidence preserved

The retained disposable validation keys (`validation/live-acceptance-20261027T120000Z-m1live/`,
`…-20261027T130000Z-m1live-r2/`, `validation/restore-test-…/`) and their cleanup-approval
boundary are untouched (separately approved operation, [../m1-final/README.md](../m1-final/README.md)).
