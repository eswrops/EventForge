GATE: PLATFORM-APPLY
APPROVER: Koka Easwarendra <easwarendra.ece@gmail.com>
DATE: 2026-10-27
COMMIT: 974c9b5c0de632c6e605a65dcc485f5ddff99aa2
PLAN_SHA256: e495af3f615e933e720462ead3f9cc69687b73b59f3a72dc03498844e0b98252

Supersedes: approvals/platform-apply-approval.md (plan 25591684…19a4), whose apply FAILED on
`oci_budget_budget.monthly` — 400-InvalidParameter "Invalid compartmentId" (CreateBudget). The
failed apply created nothing beyond what it recorded: full accounting confirmed exactly 25 of
29 planned creates are live AND in state (3 NSGs, 19 NSG rules, 2 alarms, metadata marker),
zero orphans; only the budget + its 3 dependent alert rules remain.

Root cause (documented, not retried blindly): OCI budgets are managed at the tenancy ROOT
compartment only; the reviewed configuration had placed the budget in the child Test
compartment with the deprecated `target_compartment_id`. Fix (monitoring.tf):
`compartment_id = var.tenancy_ocid`, `targets = [var.compartment_ocid]` — the provider-8.29
supported shape per the API deprecation notice.

Reviewed artifacts:
- Saved plan + JSON + action summary: /Users/eswr/secure/evidence/m1local-20261027T173633Z/plans/
  (platform-20261027T173637Z.tfplan, mode 0600)
- safe-plan policy result: PASS — exactly 4 creates (oci_budget_budget.monthly with the
  corrected compartment placement + 3 alert rules), 0 updates, 0 deletes, 0 replacements,
  0 imported-resource updates; state lineage cdda242b-92c1-4371-5b43-495f3849fc4d, serial 9.
- Failed-apply evidence preserved: /Users/eswr/secure/evidence/m1local-20261027T173416Z/
- Operator grant: "approved" (2026-10-27, in-session, for the PLATFORM-APPLY gate procedure).

Statement: this corrected plan completes the same reviewed resource set; it is applied once
with remote locking. A further failure stops again without retry or rollback.
