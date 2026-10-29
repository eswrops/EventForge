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

## B5 sequencing correction (2026-10-28 — drift-verification repair)

The verify-run "clean drift" results cited by O4 (18 PASS / 0 FAIL) were
**misleading**: the drift gate inspected only `resource_changes` and missed
that `resource_drift` carries the stale MySQL `nsg_ids` ([corrected
verdict](platform-drift-verification-repair.md)). Consequence for the B5
sequence: platform state (serial 12) still records `nsg_ids = [db-nsg]` while
the live db system has `[]` — so a MYSQL-NSG-RETEST plan built against the
current state would be a **silent no-op** on `nsg_ids`. A state-only
reconciliation package (separately approved, NOT executed) is now a mandatory
prerequisite between MYSQL-NSG-IAM and MYSQL-NSG-RETEST; the retest apply gate
additionally verifies live MySQL ACTIVE with the reviewed before-value
`nsg_ids` under the separate `GATE: MYSQL-NSG-RETEST` approval.

## B5 sequencing update (2026-10-29 — normal-refresh proof)

The 2026-10-28 sequencing note above made the state-only reconciliation a
mandatory prerequisite for MYSQL-NSG-RETEST on the assumption that a retest
plan built against the stale state (`nsg_ids = [db-nsg]`, live `[]`) would be
a silent no-op. The normal-refresh retest proof
([platform-drift-verification-repair.md §7](platform-drift-verification-repair.md))
**disproved that assumption**: a normal refreshing plan plans against the
implicitly refreshed in-memory state and yields exactly the reviewed
`[] → [db-nsg]` update (one change, no unknown attributes, dedicated retest
policy PASS at address and attribute level). The state-only reconciliation is
now an available-but-not-required option; the retest proceeds through the
unchanged gates: MYSQL-NSG-IAM apply → GATE: MYSQL-NSG-RETEST approval →
one-attempt apply of the reviewed plan.


## B5 RESOLVED (2026-10-28T22:26Z — execution record)

The MYSQL-NSG-RETEST work request **SUCCEEDED** on the one authorized attempt
after the corrective IAM policies (and the separately approved diagnostics
policy) were applied: live `rust-api-heatwave` is ACTIVE with
`nsg_ids = [eventforge-db-nsg]` and Terraform state matches live (serial 13,
lineage unchanged; `m1-verify.sh` 19 PASS / 0 FAIL, drift clean). The
earlier `AuthorizationFailed` failures are fully explained and remediated.
Full record: [b5-execution-record.md](b5-execution-record.md). Follow-ups
require their own approvals: post-retest in-VM connectivity proof (Run
Command, approval C), then the SL-CORRECTION window
([db-sl-3306-correction-approval.md](db-sl-3306-correction-approval.md)), and
diagnostics-policy removal after that window.

## Hardening close-out AUDIT-CONFIRMED + reproducibility PASS (2026-10-29)

(The follow-ups listed above were all executed 2026-10-28 under operator
approval — [b5-execution-record.md](b5-execution-record.md) Addendum 3. The
read-only audit below re-verified each item live at main `67c7991…`.)

A reproducibility/consistency audit re-verified the entire close-out and
reconciled the reported, live, and configured states
([post-b5-reproducibility-audit.md](post-b5-reproducibility-audit.md)):

| Item | Status (2026-10-29, audit-verified) |
| --- | --- |
| B5 / MySQL DB-NSG | **RESOLVED + HARDENED** — `rust-api-heatwave` ACTIVE with `nsg_ids=[eventforge-db-nsg]`; platform state `cdda242b…` serial 14 matches live |
| NSG-only database path | **VERIFIED** — db SL ingress `[]` (transitional `10.0.2.0/24 → 3306` rule gone); the app-NSG↔db-NSG 3306 pairing is the sole MySQL path |
| Both-VM post-removal connectivity | **PASS** — both VMs TCP-3306 CONNECT OK + greeting + exit 0 at 2026-10-28T23:23:49/51Z, after the rule removal |
| Diagnostics IAM policy | **REMOVED** — absent from OCI and IAM state; IAM state `2d169472…` serial 3 = exactly the two MySQL policies, both ACTIVE |
| SSH source | **/32-RESTRICTED on BOTH controls** — app SL and app NSG both pin `49.207.216.108/32`, port 22 only; `operator_ssh_cidr` input matches |
| Terraform reproducibility | **PASS** — refreshing plan (pinned 1.12.2): 37 addresses, zero changes, zero drift, no deletes/replacements, `applyable=false`; nothing applied |
| Approval-control correction | **PREPARED IN THIS TRACK** — future SSH rotations require `GATE: SSH-SOURCE-UPDATE` (dedicated apply-time recheck of the saved plan against the dedicated policy + live before-value source); 4 behavioral regression tests added |
| ONS B3 | **PENDING** (unchanged — confirmation email not clicked) |
| OCI-FEDERATION | **DEFERRED** (unchanged — Oracle SR required) |
| Application deployment | **NOT_STARTED** (unchanged — M2) |

`m1-verify.sh` re-run during the audit: **19 PASS / 0 FAIL**, drift clean.
No OCI mutation, no Terraform apply, and no state push occurred during the
audit; historical evidence above is preserved unmodified.
