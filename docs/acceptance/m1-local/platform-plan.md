# M1-LOCAL platform plan — Phase 4 review (PREPARED, not generated)

Status: **PREPARED (2026-10-27).** The additive platform plan can only be generated after the
approved imports put the eight existing resources into `platform/terraform.tfstate`
(`scripts/local/m1-platform-plan.sh` refuses otherwise). This file records the completed
review and the exact approval boundary; the saved-plan record is appended after generation.

## 1. Files reviewed (Phase 4 requirement)

| File | Review result |
| --- | --- |
| `infra/platform/network.tf` | 3 NSGs (`lb`/`app`/`db`, Test compartment, cross-compartment VCN reference — supported by OCI) + rules: HTTPS-443 only from each Cloudflare origin range; 8080 only LB-NSG→app-NSG; SSH-22 only from operator /32; 3306 only app-NSG↔db-NSG. **No public 8080/3306 anywhere.** No route-table or security-list resource is declared. |
| `infra/platform/monitoring.tf` | 2 alarms (CPU, unhealthy-backends) → ONS topic; monthly budget (amount 5, COMPARTMENT) + 3 alert rules (75/100 ACTUAL, 100 FORECAST → email). Create-only. |
| `infra/platform/load_balancer.tf` | Every resource gated by `enable_api_ingress ? … : 0` — with ingress disabled the plan contains **no** certificate, backend set, backend, or listener. |
| `infra/platform/cloudflare.tf` | DNS record + cache ruleset, same gate — **no public API DNS record, no Origin CA key generation**. |
| `infra/platform/variables.tf` | `enable_api_ingress` default false; added `vcn_compartment_ocid` (two-compartment layout). No relaxation of any validation. |

## 2. Proposed additions (all creates, all covered by `platform-safe-plan-policy.json`)

1. LB / app / DB NSGs.
2. Approved NSG rules: 15× HTTPS from the live-fetched Cloudflare origin ranges (fetched
   2026-10-27 from cloudflare.com/ips-v4, recorded in `terraform.auto.tfvars`), LB→app 8080,
   operator-S SSH 22, app→db 3306, db←app 3306.
3. Monitoring alarms ×2, monthly budget + 3 alert rules.
4. `terraform_data.api_origin_generation` marker (metadata only).
5. No deletes, no replacements, no imported-resource updates (`protected_imports` +
   `allow_import_update=false` by default; `assert-safe-plan.sh` rejects any violation).

## 3. Constraint confirmations

- Existing NSG attachments: none exist on VM VNICs or the LB — nothing can be disturbed; the
  plan does not attach NSGs to any existing resource (that remains a separate reviewed update).
- No public API listener / backend set / DNS record / Origin CA key; `enable_api_ingress=false`
  pinned in tfvars and re-checked by `m1-verify.sh` against state.
- No shared route-table or security-list mutation (no such resources declared; safe-plan denies
  deletes).
- No MySQL or compute replacement possible (imports carry `prevent_destroy`; the plan phase
  would surface any replacement as a protected-import change and fail the policy).
- Cloudflare origin ranges validated live (15 published IPv4 ranges, 2026-10-27).
- Quota / Always Free: NSGs, NSG rules, alarms (first 10 free), and budgets are free-tier;
  no Always Free consumption or quota pressure is added by this plan (see [cost.md](cost.md)).

## 4. Required operator inputs before planning

Git-ignored `terraform.auto.tfvars` placeholders must be replaced by the operator:
`cloudflare_account_id`, `cloudflare_zone_id`, `root_domain`; and the existing Cloudflare API
token exported as `TF_VAR_cloudflare_api_token` (the provider instantiates during plan even
with `enable_api_ingress=false`).

## 5. Approval boundary (STOP)

**PLATFORM-APPLY is not approved.** A passed safe-plan policy is a technical gate, not
authorization (mission rule 14): applying requires the written record
[approvals/platform-apply-approval.md](approvals/platform-apply-approval.md) (template
alongside) naming `GATE: PLATFORM-APPLY`, the exact plan SHA-256, and the source commit, plus
the matching `M1_APPLY_APPROVED_BY` attestation. Apply runs once via
`scripts/local/m1-platform-apply.sh <plan.tfplan> <metadata.json> <approval-record>` with no
new plan, no `-auto-approve`, locking retained, and no retry on failure.

## 6. Saved-plan and apply records (Phase 5 executed 2026-10-27)

**M1C-PLATFORM = PASS.** Two apply rounds under written approval records (each naming the plan
SHA-256); every production mutation used exactly one reviewed saved plan, no `-auto-approve`,
locking retained, no retry on failure.

### Round 1 — 29 creates; 25 applied, 1 error stopped the run

- Plan `255916843e5a3579a74283fe12d0b01b774daa29cbdce8842c6e237eeb7519a4`
  (evidence `/Users/eswr/secure/evidence/m1local-20261027T173304Z/`): safe-plan PASS,
  state serial 8, commit `974c9b5`.
- Apply stopped by `oci_budget_budget.monthly` → **400-InvalidParameter "Invalid compartmentId"**
  (CreateBudget). Full accounting (evidence `…/m1local-20261027T173416Z/`): exactly 25 of 29
  created live AND in state (3 NSGs, 19 rules, 2 alarms, `terraform_data` marker), **zero
  orphans** — the failed POST created nothing; budget + 3 dependent alert rules outstanding.
- Root cause: **OCI budgets are managed at the tenancy ROOT compartment only**; the reviewed
  configuration placed the budget in the child Test compartment via the deprecated
  `target_compartment_id`. Fixed in `monitoring.tf`: `compartment_id = var.tenancy_ocid`,
  `targets = [var.compartment_ocid]` (the provider-8.29 supported shape per the API
  deprecation notice). Not a blind retry — a new plan under a new approval record.

### Round 2 — the 4 outstanding creates; apply complete

- Plan `e495af3f615e933e720462ead3f9cc69687b73b59f3a72dc03498844e0b98252`
  (evidence `/Users/eswr/secure/evidence/m1local-20261027T173633Z/`): safe-plan PASS,
  exactly 4 creates (budget with corrected placement + 3 alert rules), 0 everything-else,
  state serial 9.
- Apply completed (`…/m1local-20261027T173712Z/`); state serial 10, 37 addresses total.

### Live verification (independent, `scripts/local/m1-verify.sh`)

**18 PASS / 0 FAIL** (`…/m1local-20261027T173816Z/`): 3 NSGs AVAILABLE; 19 rules with **no
public 8080/3306 exposure**; both VMs RUNNING; MySQL ACTIVE; LB unchanged flexible 10–10 with
**zero listeners**; both alarms enabled (topic `eventforge-operations`); budget
`eventforge-monthly` at the tenancy root with 3 alert rules; 37 addresses in state
(lineage `cdda242b-92c1-4371-5b43-495f3849fc4d`, serial 10); **no API-ingress resources in
state** (`enable_api_ingress=false` held); refresh-only drift **clean**.

Checker hardening during this phase (regression fixtures added, suite green):
`assert-safe-plan.sh` now distinguishes direction-aware NSG-reference unknowns — on a CREATE,
an unknown INGRESS source / EGRESS destination is acceptable only when the pinned
`*_type` proves a NETWORK_SECURITY_GROUP reference created in the same apply; unknown CIDR
endpoints, any unknown port range, and any unknown on updates remain fatal. The original
"unknown ingress attributes" rejection was over-broad: INGRESS rules legitimately plan with
unknown `destination` (an egress-only field the provider nulls at apply).
