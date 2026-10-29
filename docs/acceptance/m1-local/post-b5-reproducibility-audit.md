# Post-B5 reproducibility and acceptance-consistency audit (2026-10-29)

Read-only audit at main `67c799100611a984521e57e32bbd82193c7a9660` (PR #54):
prove the completed infrastructure is reproducible from the CURRENT
configuration, then correct the documentation and approval-control gap.
**No OCI mutation, no Terraform apply, no state push, no network change.**

## Phase 1 — read-only state reconciliation: MATCH

Every reported value was re-verified live on 2026-10-29 (verify evidence
`/Users/eswr/secure/evidence/m1local-20261028T234213Z`, audit plan evidence
`/Users/eswr/secure/evidence/audit-repro-…/`):

| Check | Reported | Live | Verdict |
| --- | --- | --- | --- |
| Main commit | 67c7991… | 67c7991… (clean tree) | MATCH |
| Platform state | lineage `cdda242b…` serial 14 | identical (m1-verify `state-readable`) | MATCH |
| IAM state | lineage `2d169472…` serial 3 | identical (`terraform state pull`, infra/iam) | MATCH |
| MySQL IAM policies | exactly 2 ACTIVE | `eventforge-mysql-nsg-membership` (Test compartment) + `eventforge-mysql-vnic-update` (tenancy root); no other eventforge policy in either compartment | MATCH |
| Diagnostics IAM policy | absent | absent from Test compartment and tenancy root (and from IAM state) | MATCH |
| MySQL | ACTIVE, DB NSG attached | `rust-api-heatwave` ACTIVE, `nsg_ids=[eventforge-db-nsg]`, state==live | MATCH |
| VM VNICs | both in app NSG | both VNICs `nsg_ids=[eventforge-app-nsg]` (exactly 1 each) | MATCH |
| DB SL transitional rule | removed | `rust-api-database-private` ingress `[]` — no `10.0.2.0/24 → 3306`, no 3306 ingress of any kind | MATCH |
| SSH controls | same approved /32 | app SL single rule TCP 22 from `49.207.216.108/32`; app NSG SSH rule source `49.207.216.108/32` | MATCH |
| Public DB exposure | none | no `0.0.0.0/0` 3306/8080 in any NSG or SL | MATCH |
| LB listeners | zero | `no-public-listener` PASS | MATCH |

`m1-verify.sh` (pinned Terraform 1.12.2, API-key DEFAULT profile): **19 PASS /
0 FAIL**, drift clean.

## Phase 2 — Terraform reproducibility: REPRODUCIBLE

- Git-ignored input `infra/platform/terraform.auto.tfvars`:
  `operator_ssh_cidr = "49.207.216.108/32"` — exactly the approved live
  source now pinned on BOTH controls (app SL and app NSG). The variable is
  /32-validated (`variables.tf`) and the file is `.gitignore`d.
- Normal refreshing plan (`terraform plan`, NOT `-refresh-only`), pinned
  Terraform 1.12.2, locking retained: **`No changes.` — 37 resource_changes,
  zero non-no-op actions, `resource_drift` empty, no deletes, no
  replacements, `applyable=false`.** No SSH source reversal, no MySQL NSG
  change, nothing proposed. Nothing was applied.

## Phase 3 — approval-control review and correction

**Deviation (documented, 2026-10-28 execution):** the SSH-SOURCE-UPDATE
rotation (plan `d7481a3f…`, serial 13→14) was reviewed at plan time against
the dedicated `platform-safe-plan-ssh-update-policy.json` (attribute-level
check PASS), but the apply consumed a **general PLATFORM-APPLY record** —
`m1-platform-apply.sh` recognized only `PLATFORM-APPLY` and
`MYSQL-NSG-RETEST`, and performed no SSH-specific apply-time recheck (the
MYSQL-NSG-RETEST gate had one). Risk: a saved SSH plan could be applied long
after review with no revalidation that the live rule still holds the reviewed
before-value source.

**Correction (this audit, no deployment change):** `m1-platform-apply.sh`
now treats a plan whose metadata names `M1_SSH_UPDATE_POLICY` as a dedicated
gate, mirroring MYSQL-NSG-RETEST:

1. The approval record must carry `GATE: SSH-SOURCE-UPDATE` (a general
   PLATFORM-APPLY record is refused; error text names all three gates).
2. The saved plan is revalidated offline against the dedicated policy
   (`assert-safe-plan-scope-a.sh`) immediately before execution.
3. The plan's before/after `source` must equal the policy's reviewed values.
4. The LIVE NSG rule (bound by rule id + NSG id from the plan) must still
   carry exactly the reviewed before-value source — a stale plan fails
   closed (`re-plan and re-review`).

Behavioral regression tests added to `tests/local/test-m1-apply-guards.sh`
(stub-terraform/oci harness, fully offline): general-record refusal,
end-to-end gated apply, stale-live-source refusal, and policy-divergent-plan
refusal. Full suite: `tests/ci/run.sh` green (safe-plan, IAM guards,
SSH-update policy fixtures, apply guards 11/11, release, acceptance 12/0).
The completed deployment was not modified by any of this (offline guards +
tests only).

## Verdict

The deployment is reproducible from the current configuration; reported
state, live state, and Terraform configuration are mutually consistent; the
approval-control gap for SSH rotations is closed and regression-tested.
