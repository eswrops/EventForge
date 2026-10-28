# B5 execution record — diagnostics IAM + MySQL DB-NSG retest (2026-10-28)

Operator authorization: mission-channel grant **"approved, do both"**
(2026-10-28T22:26Z, transcribed verbatim into both records — APPROVER
`Koka Easwarendra`; the same approval-provenance caveat documented in
[approvals/mysql-nsg-iam-approval-provenance-note.md](approvals/mysql-nsg-iam-approval-provenance-note.md)
applies: substantive authorization operator-issued, formal fields
agent-transcribed). No other mutations or retries were authorized or executed.

## Part A — IAM-RUN-COMMAND-DIAG (one diagnostics policy)

| Item | Value |
| --- | --- |
| Plan | exists-mode diagnostics plan, SHA-256 `3639345d14aad87bee1d0bcca4accdf9172f66e930ceb20ae676b8216a7da2fb`, commit `15f9135…`, contract `scripts/ci/iam-plan-contract-diag.json` (evidence `b5-diag-iam-plan-20261028T222515Z`) |
| Record | [approvals/iam-run-command-diag-approval.template](approvals/iam-run-command-diag-approval.template) copy, completed and kept OUTSIDE Git: `/Users/eswr/secure/evidence/iam-run-command-diag-approval.md` (`APPROVAL_DECISION: AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE`, all bindings filled) |
| Apply | ONE invocation of `scripts/local/m1-iam-diag-apply.sh` — all gates PASS (evidence `m1local-20261028T222555Z`); IAM state `2d169472…` serial 1 → **2**, exactly 3 `oci_identity_policy` resources |
| Result | `eventforge-instance-run-command-diagnostics` **ACTIVE**, `ocid1.policy.oc1..aaaaaaaarfejx2xlnqxtb3dlobx6joeaih32bat6v5btcr5by7wqidds2kda`, statement character-identical to the reviewed text (`use` + `request.instance.id=target.instance.id`, Test compartment) |

## Part B — MYSQL-NSG-RETEST (one attempt)

| Item | Value |
| --- | --- |
| Plan | SHA-256 `792989c59339b158086ae6ccbcc51ba76934fab9b9c62829b28af9fb01fabc63` at `15f9135…` (evidence `b5prep-retest-post48-20261028T222256Z`; exactly one `nsg_ids [] → [db-nsg]` update) |
| Record | [approvals/mysql-nsg-retest-approval.md](approvals/mysql-nsg-retest-approval.md) — GATE: MYSQL-NSG-RETEST, signed |
| Apply | ONE invocation of `scripts/local/m1-platform-apply.sh` — every gate PASS, including the live preconditions (MySQL ACTIVE, live `nsg_ids = []`, state unchanged at serial 12) (evidence `m1local-20261028T222630Z`); platform state `cdda242b…` serial 12 → **13**, lineage unchanged |
| Work request | `ocid1.mysqlworkrequest.oc1.ap-hyderabad-1.amaaaaaatiosumiaay5cpzgv4yj633vqytggryhmiyw5zombdfpnpbg6mm4a` — **SUCCEEDED** (accepted 2026-10-28T22:26:37Z) |
| Result | Live `rust-api-heatwave` **ACTIVE** with `nsg_ids = ["ocid1.networksecuritygroup.oc1.ap-hyderabad-1.aaaaaaaay3iipwy7weycrbdb7slmiu44mmhvnxsrizrrs2w7dpag5wur6hga"]` (`eventforge-db-nsg`); Terraform state matches live exactly |

## Post-execution verification

Corrected `m1-verify.sh`: **19 PASS / 0 FAIL** (evidence
`b5-resolved-verify-20261028T222907Z`) — `mysql-nsg-state-vs-live` PASS
(state and live agree), drift **clean**, all posture gates green (no public
8080/3306, LB zero listeners, ingress disabled).

## B5 status: RESOLVED

The db-NSG attachment took effect on the one authorized attempt; the earlier
failures were purely the missing IAM resource-principal policies
(AuthorizationFailed), now remediated. The app-NSG↔db-NSG 3306 pairing is now
part of the effective rule union (additive to the retained transitional
security-list rule `10.0.2.0/24 → 3306`).

## Remaining follow-ups (independent approvals)

1. **VM-CONNECTIVITY-DIAGNOSTIC-POST-RETEST (approval C)** — two in-VM
   protocol-level 3306 greetings to prove the NSG-paired path end-to-end
   (not yet executed; Run Command machinery now fully in place: plugin
   RUNNING on both VMs, policy ACTIVE).
2. **SL-CORRECTION** — after an observation window, remove the transitional
   `rust-api-database-private` `10.0.2.0/24 → 3306` ingress rule
   ([db-sl-3306-correction-approval.md](db-sl-3306-correction-approval.md),
   prepared, requires fresh manifests at execution time).
3. Diagnostics policy removal — `eventforge-instance-run-command-diagnostics`
   should be destroyed after the diagnostic window (separate
   destroy-approving package).

## Addendum (2026-10-28T22:50Z): follow-up execution outcome — Run Command path BLOCKED, SL-CORRECTION deferred

Operator follow-up authorization "approve all" (2026-10-28T22:34Z) covered
approval C, SL-CORRECTION, and diagnostics-policy removal. Outcome:

1. **Approval C — ATTEMPTED, BLOCKED (fail-closed, no broadening).** Two Run
   Command executions were created for `rust-api-test` (one was an accidental
   duplicate caused by an agent-side CLI parse error masking a successful
   first create — documented as a deviation; both commands are the identical
   read-only script). Despite the plugin reporting RUNNING and the execution
   record existing (`ACCEPTED`, delivery `VISIBLE`), the command remained
   stuck at **ACCEPTED for 14+ minutes** and was never picked up or completed
   — exactly the retained operational caveat ("policy creation does not prove
   command completion"). Per the fail-closed rule the Run Command route is
   STOPPED: no command completed, no in-VM evidence was produced, and the
   policy is NOT broadened in place. Evidence:
   `/Users/eswr/secure/evidence/b5-connectivity-attempt-20261028T2235Z/`.
   Recovery options requiring a NEW operator decision: (a) a re-reviewed
   policy package broadening the instance grant (e.g. the Oracle-documented
   `manage instance-agent-command-execution-family` dynamic-group form, or
   adding `instance-agent-command-family` read) — a NEW package, not a
   modified record; (b) refreshing the SSH source /32 (separate SL change);
   (c) Oracle SR. The two stale VM1 commands remain inert (never executed).

2. **SL-CORRECTION — NOT executed.** Its precondition 3 (fresh in-VM evidence
   that the NSG-paired path carries 3306) cannot be satisfied while the Run
   Command path is blocked, and no SSH vantage is available (IP rotation).
   Removing the transitional `10.0.2.0/24 → 3306` rule without any in-VM
   verification path risks silently cutting app→MySQL connectivity. The rule
   is RETAINED; the package stays prepared.

3. **Diagnostics-policy removal — NOT executed.** Removing
   `eventforge-instance-run-command-diagnostics` now would eliminate the only
   prepared diagnostic path while connectivity verification is still pending;
   it also mechanically requires a PR (the resource carries
   `prevent_destroy`). Deferred until the diagnostic window actually closes.

Config-level posture (read-only, supporting the eventual SL-CORRECTION):
the db NSG carries the reviewed 3306 ingress from the app NSG, the app NSG
carries the symmetric egress, and both VM VNICs + the MySQL db system hold
their NSG memberships — the pairing is correctly configured; what is missing
is only the runtime proof through it.
