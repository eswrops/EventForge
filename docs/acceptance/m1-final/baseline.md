# M1 final — Phase 0 baseline (reconciled actual state)

Generated: 2026-10-27 · Reconciled at git commit `1e06e7f496c988c32c1fc462d7314b8e7dd74134`
(origin/main, [PR #10](https://github.com/eswrops/EventForge/pull/10) squash-merged 2026-10-27T04:52:21Z)
· Mission: complete remaining M1 work (GitHub security → OCI bootstrap → remote state →
federation → imports → additive platform → acceptance report).

This file records the reconciled starting state for the M1-final run. All findings below were
re-verified live during this reconciliation, not copied from earlier evidence.

## 1. Git and CI status

| Item | Value |
| --- | --- |
| Starting commit | `1e06e7f496c988c32c1fc462d7314b8e7dd74134` (main, clean tree) |
| PRs merged so far | #1–#10 (all MERGED; #10 = GitHub lockdown evidence, squash-merged under the new protection) |
| Latest CI | run [40451969065](https://github.com/eswrops/EventForge/actions/runs/40451969065) — Terraform, PR #10, all four required contexts success |
| Merge methods | squash/rebase/merge all enabled (squash+merge used post-linear-history; PR #10 proves the path) |
| `git diff --check` | clean |
| Secret scanning | enabled, push protection enabled, 0 alerts (validity checks disabled — optional hardening) |
| Local verification | `scripts/acceptance/run.sh` PASS=12 FAIL=0 · `tests/ci/run.sh` PASS=12 FAIL=0 |

## 2. Tool versions

| Tool | Version | Note |
| --- | --- | --- |
| Terraform (CI-pinned) | 1.12.2 | Required for the bootstrap apply and all gated plans |
| Terraform (local default) | 1.17.0 | Homebrew; preflight flags `tf-version` BLOCKED until a checksum-verified 1.12.2 binary is used |
| Provider `oracle/oci` | 8.29.0 | bootstrap + platform lockfiles |
| Provider `cloudflare/cloudflare` | 5.28.1 | platform + frontend lockfiles |
| Provider `hashicorp/tls` | 4.4.2 | platform lockfile |

## 3. Offline gate results (re-run during reconciliation)

- Acceptance harness: **PASS 12 / FAIL 0** (includes shellcheck, actionlint, secret scan,
  ingress-disabled, action-pin, safe-plan fixture, WIF fixture, KMS policy-string checks).
- CI fixture suite: **PASS 12 / FAIL 0**.
- Preflight `--mode pre-bootstrap`: **PASS=18 FAIL=0 NOT_RUN=1 BLOCKED=3**. The three BLOCKED
  items are exactly the operator-held prerequisites, not defects:
  1. `tf-version` — run the first apply with the CI-pinned 1.12.2 binary (local default 1.17.0).
  2. `operator-inputs-bootstrap` — `infra/bootstrap/terraform.auto.tfvars` is operator-held (correct).
  3. `oci-cmk` — the state CMK decision/creation is pending (operator checklist step 7).

## 4. Current GitHub protections (live, re-verified read-only)

| Setting | Live value |
| --- | --- |
| Branch protection on `main` | PRs required; required contexts `Format and validate (infra/bootstrap|platform|frontend)`, `CI script and workflow checks`; strict=true; enforce_admins=true; force pushes/disabled; deletion disabled; linear history enabled; `required_approving_review_count=0`; dismiss_stale_reviews=true; require_last_push_approval=false |
| Actions `allowed_actions` | `selected`, `sha_pinning_required=true` |
| Selected-actions | `github_owned_allowed=false`, `verified_allowed=false`, exactly the 4 SHA-pinned patterns of `scripts/ci/action-allowlist.json` |
| Default workflow permissions | `read`; `can_approve_pull_request_reviews=false` |
| Environments | `production-plan` (25412942570), `production` (25412943777) — reviewer 237514587, `prevent_self_review=false`, single main branch policy each (preflight PASS both) |
| Evidence | [../m1b2b/lockdown-applied.json](../m1b2b/lockdown-applied.json) (applied 2026-10-27T04:49Z under operator "do it"); independently re-verified this session via read-only API |

Phase 1 (GH-SECURITY) therefore starts from **applied** state; its remaining live acceptance is
verification only (docs-only PR smoke, direct-push rejection, OIDC inspection re-run).

## 5. Existing OCI resources (live, read-only re-verification)

Tenancy `easwarendraece`, home region `ap-hyderabad-1`, namespace `axrq1dasyz3y`. Verified OCIDs:
[../m1b/import-reconciliation.json](../m1b/import-reconciliation.json).

| Resource | Live state | Status |
| --- | --- | --- |
| `rust-api-test` (VM.Standard.E2.1.Micro, 10.0.2.129) | running | preflight `oci-inventory-match` PASS |
| `rust-api-worker` (VM.Standard.E2.1.Micro, 10.0.2.94) | running | preflight `oci-inventory-match` PASS |
| `rust-api-heatwave` (MySQL.Free, 10.0.3.18:3306) | ACTIVE | re-verified this session |
| `rust-api-public-lb` (Flexible 10 Mbps, 129.159.239.48) | ACTIVE, no listeners | re-verified this session |
| VCN `postgresmax-vcn` 10.0.0.0/16 + 3 subnets (app 10.0.2.0/24, db 10.0.3.0/24, lb 10.0.4.0/24) | unchanged | unmanaged until the reviewed import flow (preflight `shared-network-unmanaged` PASS) |
| Object Storage buckets | **0** in root and Test compartments | pristine pre-bootstrap state |
| Vault `rust-api-secrets` | ACTIVE (root compartment) | re-verified this session |
| Key `rust-api-secret-key` | ENABLED, AES, SOFTWARE protection | the only key; no dedicated state key exists yet |
| Dynamic groups | 0 | none exist |
| EventForge/GitHub/ObjectStorage-related IAM policies (root + Test) | 0 | none exist |

## 6. Remaining gates (Phase 1 → Phase 9)

| Phase | Gate | Current status |
| --- | --- | --- |
| 1 | GH-SECURITY | Applied + preflight PASS; live acceptance (smoke PR, push rejection, OIDC re-run) outstanding |
| 2 | BOOTSTRAP-PLAN | BLOCKED on checklist step 7 (CMK decision) then step 8 (real plan review) |
| 3 | OCI-BOOTSTRAP | BLOCKED on step 9 approval + tfvars + 1.12.2 binary |
| 4 | OCI-REMOTE-STATE | BLOCKED on bootstrap (needs bucket) |
| 5 | OCI-FEDERATION | BLOCKED on trusts/clients (steps 10–11); production subject not yet inspected |
| 6 | OCI-IMPORTS | BLOCKED on remote state |
| 7 | M1C-PLATFORM | BLOCKED on imports |
| 8 | RELEASE-OPERATIONS | NOT_RUN (dry-runs are local; can proceed independently) |
| 9 | M1 final report | pending all above |

First operator decision required: **checklist step 7 — approve creation of the dedicated state
CMK `eventforge-tfstate-key` in vault `rust-api-secrets`** (recommended; alternatively record
explicit selection of reusing `rust-api-secret-key`, which is not recommended).
