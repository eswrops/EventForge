# State safety, lock validation, and recovery

Status: Stage 1 bootstrap resources are created. Every live command below remains a
separately approved checklist step; in particular, backend migration is a production
state write and is not performed by any preflight or CI job.
All lock, contention, and destructive probes use the disposable
`validation/<timestamp>/terraform.tfstate` key — **never** the production keys
(`bootstrap/terraform.tfstate`, `platform/terraform.tfstate`, `frontend/terraform.tfstate`).
`terraform force-unlock` and `terraform state push -force` are prohibited against production state.

## 1. Native OCI backend declaration and migration

Each Terraform root declares exactly one empty `backend "oci" {}` block. The operator
workstation uses the verified OCI CLI **API-key** `DEFAULT` profile, not ResourcePrincipal
(no Resource Principal environment is available on that workstation). GitHub remains on the
ResourcePrincipal path only after the separately approved federation work.

For a migration, copy the root's example to ignored `backend.hcl` and use only non-secret values:

```hcl
bucket              = "eventforge-tfstate-prod"
namespace           = "axrq1dasyz3y"
key                 = "bootstrap/terraform.tfstate" # platform/frontend use their own key
region              = "ap-hyderabad-1"
auth                = "APIKey"
config_file_profile = "DEFAULT"
```

After explicit `STATE-MIGRATION` approval, migrate **only** the bootstrap root:

```bash
OCI_CLI_CONFIG=/Users/eswr/.oci/config \
  /Users/eswr/tools/terraform/1.12.2/terraform -chdir=infra/bootstrap \
  init -migrate-state -backend-config=backend.hcl
```

- Bootstrap migrates its existing eight-resource state into `bootstrap/terraform.tfstate`.
  Platform and frontend retain independent keys and are initialized only when their own approved
  workflows need them. Do not use `init -reconfigure`, `init -force-copy`, `state push -force`,
  or `force-unlock` as a migration substitute.
- `-input=false` is intentionally omitted: Terraform must present the copy confirmation and the
  operator must answer only after the displayed destination matches this approved bucket and key.
- The API-key file stays in the OCI CLI configuration; neither `backend.hcl` nor Git contain a
  private-key path, fingerprint, or credential value.

## 2. State-integrity preflight and backup (mandatory before migration)

Record the source lineage, serial, addresses, IDs, commit, and backup hash before migration:

```bash
terraform -chdir=infra/bootstrap state pull > /secure/evidence/bootstrap-pre-migration.tfstate
jq -r '[.lineage, .serial] | @tsv' /secure/evidence/bootstrap-pre-migration.tfstate
sha256sum /secure/evidence/bootstrap-pre-migration.tfstate
terraform -chdir=infra/bootstrap state list
oci os object head --bucket-name eventforge-tfstate-prod --name bootstrap/terraform.tfstate
```

The final `object head` must report the key as absent before first migration. Also require no
active Terraform process or local state lock, the state bucket to be private/versioned/CMK-bound,
and the operator API-key profile to initialize a disposable native backend successfully.

```bash
# One-off manual backup, stored OUTSIDE the repository (never committed, never in CI artifacts):
terraform -chdir=infra/bootstrap state pull > /secure/evidence/bootstrap-pre-<step>-$(date -u +%Y%m%dT%H%M%SZ).json
```

Keep at least one backup taken immediately before: the backend migration, each import, and any
apply. Backups contain sensitive values (Origin CA private keys) — store them with the same
protection as the state bucket itself.

## 3. Disposable backend-init check (no remote state write)

Before approving migration, test only authentication/configuration against a unique disposable
key. This command performs backend initialization and confirms the key stays absent; it does not
run a plan, apply, lock, or state write.

```bash
TF_STATE_BUCKET=eventforge-tfstate-prod \
OCI_OBJECT_STORAGE_NAMESPACE=axrq1dasyz3y \
OCI_REGION=ap-hyderabad-1 \
TERRAFORM_BIN=/Users/eswr/tools/terraform/1.12.2/terraform \
scripts/acceptance/oci-backend-init-preflight.sh
```

The probe reports authorization, configuration, and other initialization failures distinctly.

## 4. Backend health check (after approved migration)

```bash
terraform -chdir=infra/bootstrap state list          # proves read + auth
scripts/ci/verify-oci-backend.sh                      # disposable-key write/read/lock/contention/release
```

## 5. Isolated backend lock validation (checklist step D)

`scripts/ci/verify-oci-backend.sh` (already committed; CI-proven syntax) creates a disposable
`terraform_data` probe on `validation/.../terraform.tfstate`, holds its lock for ~15 s, expects a
concurrent plan to fail **with a lock error**, releases on destroy, and proves a post-destroy plan
can acquire the lock. It prints the retained validation key for operator review. While the first
lock is held, list the bucket objects and **record the exact lock-object suffix** — that string
finalizes the `target.object.name matches /.*lock.*/i` pattern in
[federation.md](federation.md) §C.

Then run `scripts/ci/verify-oci-backend-denied.sh` with an explicitly underprivileged resource
principal against the same disposable key and record the redacted authorization denial.

## 6. State encryption validation

```bash
oci os bucket get --bucket-name eventforge-tfstate-prod | jq '.data."kms-key-id", .data."versioning"'
oci os object head --bucket-name eventforge-tfstate-prod --name bootstrap/terraform.tfstate \
  | jq '."kms-key-id", ."version-id"'
```

Expect: bucket `kms-key-id` = the CMK OCID, `versioning = Enabled`, and the object carrying the
same key id. Record both in the evidence log.

## 7. State version recovery test (checklist step G, disposable key first)

The lifecycle policy deletes noncurrent state versions after `state_version_retention_days` (30).
Recovery = copy a prior version back over the live key (never `state push -force`):

```bash
# 1. List versions of the disposable key and pick a prior version-id:
oci os object list-versions --bucket-name eventforge-tfstate-prod \
  --prefix validation/ | jq -r '.data[] | select(."version-id" != null) | ."name", ."version-id"'
# 2. Restore by copying that version onto a scratch key first (validation/restore-test/...):
oci os object copy --source-bucket eventforge-tfstate-prod --source-object-name <name> \
  --source-version-id <version-id> --destination-bucket eventforge-tfstate-prod \
  --destination-object-name validation/restore-test/terraform.tfstate --destination-region ap-hyderabad-1
# 3. terraform state pull on a scratch backend pointing at the scratch key must succeed.
# 4. Only after the scratch rehearsal: repeat onto the real key if a real recovery is needed,
#    with a fresh manual backup taken immediately beforehand.
```

For production recovery: take a fresh `terraform state pull` backup, restore the chosen prior
version onto the production key with the same copy command, run `terraform plan -refresh-only`,
and reconcile any drift deliberately. Note: objects encrypted with a CMK are re-encrypted on
copy — the bucket's current key must still be enabled for the copy to succeed; this is why key
loss without backups is unrecoverable.

## 8. Refresh-only reconciliation (after imports; see import-safety.md §4)

```bash
terraform -chdir=infra/platform plan -refresh-only -out=refresh.tfplan
terraform -chdir=infra/platform show -json refresh.tfplan | jq -r '
  .resource_changes[] | select(.change.actions != ["no-op"]) | "\(.address): \(.change.actions|join(","))"'
```

Any non-no-op line is drift to be investigated and approved line-by-line before a normal plan;
drift is never auto-corrected.

## 9. Rollback strategy summary

| Situation | Rollback |
| --- | --- |
| Failed bootstrap apply | `terraform apply` is not partially committed; fix inputs and re-plan. Buckets/policies created are removable via the operator console after review (never `terraform destroy` against production without a separate approval). |
| Bad backend migration | Preserve the local backup kept in §2, verify whether the remote key was written, and stop for incident approval. Never overwrite remote state with `state push -force`; use the documented version-copy recovery only after approval. |
| Lock stuck on a disposable key | Wait for the 15 s probe to finish or delete the disposable lock object after positively verifying its `validation/` prefix. |
| Lock stuck on production | Never `force-unlock`. Verify no plan/apply is running (Actions run history), then use the documented incident procedure: confirm the lock object's age/owner, remove the lock object via the operator session with an explicit approval record, and re-lock. |
| Bad state write | Copy the prior version back (§6) after a fresh backup. |
