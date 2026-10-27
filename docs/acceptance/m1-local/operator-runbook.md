# M1-LOCAL operator runbook (macOS workstation)

Controlled local deployment replaces GitHub Actions as the infrastructure executor.
GitHub stays source control + PR CI; it is never the deployment executor. All commands
run from the repository root with Terraform pinned at 1.12.2
(`/Users/eswr/tools/terraform/1.12.2/terraform`) and the OCI CLI API-key `DEFAULT` profile.

## Evidence and secrets layout

| Path | Role |
| --- | --- |
| `/Users/eswr/secure/evidence/m1local-*/` | Per-run evidence (plans, state snapshots, logs) — mode 0700, outside the repository |
| `/Users/eswr/secure/secrets/` | Operator secrets (never printed, never committed) |
| `infra/platform/backend.hcl`, `terraform.auto.tfvars`, `imported_resources.tf`, `terraform.tfvars` | Git-ignored operator configuration |
| `docs/acceptance/m1-local/` | This acceptance track (committed, sanitized) |

## Sequence

### 0. Baseline preflight (read-only, run any time)

```bash
scripts/local/m1-preflight.sh
```

Verifies: pinned Terraform 1.12.2, API-key `DEFAULT` (rejects Resource/Instance Principal),
bucket private+versioned+CMK-bound, CMK ENABLED, bootstrap lineage
`a79177dd-2c02-084e-ddf6-29f346b2fa78` with exactly 8 addresses, no lock objects, no
`platform/terraform.tfstate`, repository hygiene (no credentials/state tracked), dormant
dispatch-only WIF workflows. **Any FAIL stops the mission (rule 15).**

### 1. Inventory (read-only)

```bash
scripts/local/m1-oci-inventory.sh
```

Reconciles the eight reviewed OCIDs against the live estate and writes the discovery bundle.

### 2. Platform backend init (first platform state workflow)

```bash
scripts/local/m1-platform-init.sh
```

Refuses pre-existing local platform state; if `platform/terraform.tfstate` already exists
remotely it snapshots it and requires `M1_ALLOW_EXISTING_STATE=<lineage>` after operator
review. Never uses `-migrate-state` / `-reconfigure` / `-force-copy`. Init writes no remote
object (verified post-init).

### 3. Imports — REQUIRES APPROVAL (imports.md §5)

Before running: supply the MySQL admin credential pair from the operator vault. Prefer a
protected operator-local secret source over editing files:

```bash
mkdir -p /Users/eswr/secure/secrets/eventforge-platform
umask 077
cat > /Users/eswr/secure/secrets/eventforge-platform/mysql.tfvars <<'EOF'
mysql_admin_username = "<from operator vault>"
mysql_admin_password = "<from operator vault>"
EOF
```

That file lives outside the repository (mode 0600, git cannot see it); the import script is
invoked with `M1_EXTRA_VAR_FILE=/Users/eswr/secure/secrets/eventforge-platform/mysql.tfvars`,
or the values are exported as `TF_VAR_mysql_admin_username` /
`TF_VAR_mysql_admin_password` for the single command. Never copy plaintext credentials into
`terraform.tfvars` in the repository, into acceptance evidence, or into logs; the import and
plan scripts never print variable files. If a repository `terraform.tfvars` is used instead
(last resort), it must be mode 0600 — it is git-ignored and the preflight refuses to track it.

```bash
M1_IMPORT_APPROVED_BY="<name+date>" scripts/local/m1-platform-imports.sh
```

### 4. Plan → review → apply — SEPARATE APPROVALS

```bash
scripts/local/m1-platform-plan.sh            # saved plan + JSON + summary + SHA-256 + metadata + safe-plan result
scripts/local/m1-platform-apply.sh <plan.tfplan> <metadata.json> <approval-record>
```

The plan artifacts live in the run's evidence directory (plans and their JSON are mode 0600 —
they can carry sensitive values). The apply requires a written approval record
(`docs/acceptance/m1-local/approvals/platform-apply-approval.md`, template alongside) carrying
`GATE: PLATFORM-APPLY`, the plan's SHA-256, the source commit, and an `APPROVER:` line, plus
the matching `M1_APPLY_APPROVED_BY` attestation — a passed safe-plan policy is not
authorization, and no environment variable alone grants it. The apply refuses any mismatch
(plan SHA-256, source commit, safe-plan verdict, remote state lineage/serial since plan), never
generates a plan, never uses `-auto-approve`, and marks metadata applied so a plan cannot be
applied twice.

Operator inputs required before planning (git-ignored tfvars / environment):
`cloudflare_account_id`, `cloudflare_zone_id`, `root_domain`, `TF_VAR_cloudflare_api_token`
(existing token; the plan instantiates the Cloudflare provider even with
`enable_api_ingress=false`).

### 5. Verification (read-only)

```bash
scripts/local/m1-verify.sh
```

Live checks: 3 NSGs + rules, no public 8080/3306 exposure, VMs RUNNING, MySQL ACTIVE, LB
unchanged with no listeners, alarms enabled, budget + alert rules, state inventory, ingress
resources absent, and a read-only refresh-only drift assessment. A failed OCI listing is
never treated as absence.

## Invariants (mission rules encoded in the scripts)

- Locking always retained (`-lock=true`; `-lock=false` anywhere is refused).
- No `state push -force`, no `force-unlock` — recovery is the documented manual
  version-copy procedure ([../m1b-bootstrap/state-recovery.md](../m1b-bootstrap/state-recovery.md) §7).
- No plan/apply from GitHub Actions (`workflow_dispatch`-only workflows stay dormant; no
  dispatches, no tag pushes during this mission).
- No retry after failed import/apply; failure evidence preserved under `logs/`.
- Production applies only from a reviewed saved plan; `-auto-approve` prohibited.
- Sensitive artifacts (plans, state pulls, logs) stay outside the repository.
