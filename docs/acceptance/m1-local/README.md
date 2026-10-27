# M1-LOCAL — workstation deployment acceptance track

This directory records the M1-LOCAL mission: replacing GitHub Actions with a controlled
local-workstation deployment workflow so infrastructure acceptance can continue while OCI
workload federation is blocked on Oracle enablement. The GitHub federation clients/trust and
their evidence (`../m1-final/workload-federation.md`, commits `974c9b5` and ancestors) are
untouched; GitHub remains source control and PR-CI, not the deployment executor.

Mission markers (fixed for this track):

```
DEPLOYMENT_MODE      = LOCAL_OPERATOR
OCI_FEDERATION       = DEFERRED
GITHUB_STAGE_2_IAM   = DEFERRED
```

These deferred markers are intentionally **not** PASS; they resume only through the documented
Oracle-SR path in [../m1-final/workload-federation.md](../m1-final/workload-federation.md).
The original full-M1 gate table in [../m1-final/README.md](../m1-final/README.md) is historical
and is not rewritten by this track.

## Files

| File | Content |
| --- | --- |
| [README.md](README.md) | This file — mission markers, baseline record, gate status |
| [operator-runbook.md](operator-runbook.md) | Local script usage, approval-gate procedure, evidence locations |
| [imports.md](imports.md) | Phase 2 inventory + Phase 3 import execution record |
| [platform-plan.md](platform-plan.md) | Phase 4 saved-plan record and safe-plan policy result |
| [security.md](security.md) | Post-apply network security verification |
| [next-ingress-security-approval.md](next-ingress-security-approval.md) | Prepared change package for the future ingress gate: effective rule union, legacy-rule findings, scope-A/scope-B separation, sequencing, rollback, expected plan actions |
| [cost.md](cost.md) | Quota / Always-Free / budget findings |
| [blockers.md](blockers.md) | Blockers and deferred items |
| [m1-local-report.json](m1-local-report.json) | Machine-readable gate summary |

## Phase 0 — M1-LOCAL baseline record (2026-10-27)

All checks read-only. Evidence directory (operator workstation, outside the repository,
mode 0700): `/Users/eswr/secure/evidence/m1local-20261027T154030Z/`.

| Check | Result |
| --- | --- |
| Operator identity | `easwarendra.ece@gmail.com` (`ocid1.user.oc1..aaaaaaaajkgm655z4laek4fguupilgn6qnwa4g3gxo5frybr7syjtdnigskq`), OCI CLI 3.95.1, API-key profile `DEFAULT` — live auth proven by successful reads |
| Git revision | `974c9b5c0de632c6e605a65dcc485f5ddff99aa2` (2026-10-27T19:51:20+05:30), clean working tree at baseline start |
| Terraform | `/Users/eswr/tools/terraform/1.12.2/terraform` → `Terraform v1.12.2 on darwin_arm64` (pinned path used by all scripts) |
| Region | `ap-hyderabad-1` (OCI CLI profile and backend config agree) |
| Namespace | `axrq1dasyz3y` (live `oci os ns get`) |
| State bucket | `eventforge-tfstate-prod`: `NoPublicAccess`, `versioning = Enabled`, CMK-bound to `ocid1.key.oc1.ap-hyderabad-1.gfvn7rbsaab4m.abuhsljrfq3gaqtpyejt5gfe4cra2fa6hhzuyqicb6vhevlspuujd3srbcyq` |
| CMK | **ENABLED** — vault `rust-api-secrets` (`ocid1.vault.oc1.ap-hyderabad-1.gfvn7rbsaab4m.abuhsljrdq32j4pb5cwcaya2chgt7llct46eumxquvmt6uo3fkm4nm7loahq`), SOFTWARE protection, endpoint `https://gfvn7rbsaab4m-management.kms.ap-hyderabad-1.oci.oraclecloud.com` (note: vault endpoints use `<hash>-management.kms.<region>.oci.oraclecloud.com`; the older `<hash>.management.<region>.oraclecloud.com` pattern does not resolve) |
| Bootstrap remote state | Readable via `terraform state pull`; lineage `a79177dd-2c02-084e-ddf6-29f346b2fa78`, serial `1`, exactly the expected 8 addresses (`oci_identity_dynamic_group.eventforge_instances`, `oci_identity_policy.eventforge_instance_backups`, `oci_identity_policy.objectstorage_kms`, `oci_objectstorage_bucket.backups`, `oci_objectstorage_bucket.terraform_state`, `oci_objectstorage_object_lifecycle_policy.terraform_state_versions`, `oci_ons_notification_topic.operations`, `oci_ons_subscription.operations_email`) — pulled copy saved as `bootstrap-phase0-pull.tfstate` in the evidence directory |
| Terraform writers / locks | No running terraform processes; **no `.lock` objects** under `bootstrap/`, `platform/`, `frontend/` (fully-paginated listing). Bucket object inventory: `bootstrap/terraform.tfstate` (16430 B, 2026-10-27T07:28:36Z) plus the retained disposable validation keys (`validation/live-acceptance-20261027T120000Z-m1live/…`, `…-m1live-r2/…`, `validation/restore-test-…/…`) which remain untouched pending separately approved cleanup |
| Platform state key | `platform/terraform.tfstate` **does not exist yet** — Phase 3 init will create it as the first write (no pre-existing object to snapshot) |
| GitHub WIF workflows | All infrastructure workflows (`terraform-plan.yml`, `terraform-apply.yml`, `frontend.yml`, `oci-backend-validation.yml`, `oci-preflight.yml`, `oci-wif-exchange-probe.yml`, `oidc-claim-inspection.yml`) are `workflow_dispatch`-only — they cannot fire from local deployment activity. `terraform.yml` triggers on `pull_request` (offline PR CI only); `release.yml` triggers on `v*` tag push (no tags are pushed during this mission). All remain **dormant**; evidence untouched |
| Credentials | No credentials printed or committed; backend config carries only non-secret coordinates (bucket/namespace/key/region/auth/profile) |

## Gate status

| Gate | Status |
| --- | --- |
| M1-LOCAL BASELINE (Phase 0) | **PASS** — record above |
| LOCAL-SCRIPTS (Phase 1) | **PASS** — `scripts/local/` guard library + 8 scripts; offline tests `tests/local/test-m1-local-guards.sh` PASS; full harness `tests/ci/run.sh` PASS (12/12, shellcheck clean); live preflight 15/15 PASS |
| PRE-IMPORT SECURITY REVIEW | **PASS (2026-10-27)** — gitignore hardening (`terraform.tfvars`/`terraform.tfvars.json` now ignored, verified by `git check-ignore`); tracked/staged content audited clean; all 8 scripts re-audited against the 13 review requirements with fixes: written approval records now required for imports/apply/init-existing-state (no env-only authorization), `M1_EXTRA_VAR_FILE` secret-source contract (0600, outside repo), explicit 0600 on plans/JSON/state snapshots, workspace check in verify, shellcheck clean. One real config defect caught and fixed: app-subnet security-list OCID transcription (`m1-verify-import-config.sh` 34/0 PASS against the live bundle; all 8 import OCIDs verified char-for-char) |
| OCI-INVENTORY (Phase 2) | **PASS** — 16 PASS / 0 FAIL, all 8 reviewed OCIDs reconciled live ([imports.md](imports.md)) |
| OCI-IMPORTS (Phase 3) | **PASS (2026-10-27)** — 8/8 reviewed resources imported under the operator's written approval (commit `974c9b5`), every state ID verified against the reviewed OCID, serial 8, refresh-only reconciliation clean (zero resource changes); live estate untouched ([imports.md](imports.md) §6) |
| M1C-PLATFORM (Phase 4/5) | **PASS (2026-10-27)** — two SHA-bound apply rounds (29-create plan: 25 applied, budget 400 root-caused and fixed in config; 4-create follow-up plan completed), 37 addresses in state (serial 10), live verification **18 PASS / 0 FAIL**, zero drift, ingress disabled, zero orphans ([platform-plan.md](platform-plan.md) §6) |
| DECLARATIVE-REPRODUCIBILITY | **PASS (2026-10-27)** — the eight imported-resource declarations are tracked in Git (discovery values in ignored `imported.auto.tfvars`); a clean checkout with the protected inputs plans **zero changes** against the offline state copy (37 no-op addresses) |
| NETWORK-SECURITY-ENFORCEMENT | **PASS (2026-10-27, live inspection)** — effective posture verified closed: no public 8080/3306 anywhere, LB zero listeners, MySQL private-only, app→MySQL works; created NSGs are attached to nothing and stay that way until the separately reviewed ingress gate ([security.md](security.md)) |
| OPERATIONS (Phase 6) | **PASS (review)** — release/rollback procedures sound; ONS subscription still PENDING (see [blockers.md](blockers.md) B3); application deployment NOT claimed |
| LOCAL-DEPLOYMENT-TOOLING | **PASS (2026-10-27)** — reviewed and merged as [PR #36](https://github.com/eswrops/EventForge/pull/36) (squash commit `e93bfc4`, 4/4 required checks); behavioral guard tests green in CI |
| M1-LOCAL REPORT (Phase 7) | **PASS** — [m1-local-report.json](m1-local-report.json) (final commit `e93bfc4`) |
| OCI-FEDERATION (from full M1) | DEFERRED — Oracle SR required; clients/trust untouched |
| GITHUB-STAGE-2-IAM | DEFERRED — behind federation |
| IAM-DENIAL | NOT_RUN — unchanged (needs an underprivileged principal; refuses `DEFAULT` by design) |

**M1-LOCAL overall: PASS as a local-infrastructure acceptance track up to its approval
boundaries.** The original full-M1 gate remains BLOCKED where GitHub workload federation or its
security acceptance is still required; historical acceptance records were not modified.

## Final acceptance consistency re-verification (2026-10-28, close-out)

All read-only. Main = `ae25230c` (contains PR #36 `e93bfc4` + PR #37, both merged with 4/4
required checks green on their head commits: the three `Format and validate (infra/{bootstrap,platform,frontend})`
contexts + `CI script and workflow checks`). Re-verified live this date:

| Check | Result |
| --- | --- |
| Remote platform state | lineage `cdda242b-92c1-4371-5b43-495f3849fc4d`, serial **10** — unchanged |
| `scripts/local/m1-verify.sh` | **18 PASS / 0 FAIL** (VMs RUNNING, MySQL ACTIVE, LB zero listeners, NSGs attached to nothing, alarms + budget present, drift clean) |
| Clean-checkout platform plan | **no-op** — `changes=0`, safe-plan policy PASS, no remote locks, `enable_api_ingress` still refused |
| Import declarations | 8/8 tracked in `imported_resources.tf` (8 `prevent_destroy`) |
| Protected input files | `backend.hcl`, `terraform.auto.tfvars`, `imported.auto.tfvars`, `terraform.tfvars` all still git-ignored (`git check-ignore` verified) |
| ONS subscription | still **PENDING** (`eswr.ops@gmail.com`, topic `eventforge-operations` ACTIVE) — operator confirmation action recorded in [blockers.md](blockers.md) B3 |
| Next-gate package | [next-ingress-security-approval.md](next-ingress-security-approval.md) prepared (no changes applied) |

Statuses retained: **OCI-FEDERATION = DEFERRED, STAGE-2-IAM = NOT_APPLIED,
IAM-DENIAL = NOT_RUN, ONS-DELIVERY = PENDING.** None were converted to PASS.
