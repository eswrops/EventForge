# OCI bootstrap readiness

Status: **READY TO EXECUTE after operator approval.** Nothing has been applied to OCI. The offline
plan below was produced with placeholder inputs and **no provider API calls** (the bootstrap root
declares no data sources); it never touched the tenancy.

## 1. Proposed resource inventory (offline plan, Terraform 1.12.2)

`terraform plan -input=false -refresh=false` on `infra/bootstrap` (placeholder tfvars, no state)
reports **exactly 10 creates, 0 changes, 0 destroys**:

| # | Address | Resource | Purpose |
| --- | --- | --- | --- |
| 1 | `oci_objectstorage_bucket.terraform_state` | bucket `eventforge-tfstate-prod` (default) | Terraform state and locks; `NoPublicAccess`, versioning **Enabled**, CMK `kms_key_id`, Standard tier |
| 2 | `oci_objectstorage_bucket.backups` | bucket `eventforge-backups` (default) | VM backup artifacts; `NoPublicAccess`, versioning **Enabled** |
| 3 | `oci_objectstorage_object_lifecycle_policy.terraform_state_versions` | lifecycle rule | Deletes noncurrent state versions after `state_version_retention_days` (default 30) |
| 4 | `oci_identity_dynamic_group.eventforge_instances` | dynamic group | Matches exactly the two existing VM OCIDs via `instance.id = '...'` |
| 5 | `oci_identity_policy.eventforge_instance_backups` | policy | Instances may manage/inspect objects only in `eventforge-backups` |
| 6 | `oci_identity_policy.objectstorage_kms` | policy *(added in M1B.1)* | `Allow service objectstorage_<region> to use keys ... where target.key.id = '<CMK>'` — without it the CMK-encrypted bucket cannot be created |
| 7 | `oci_identity_policy.github_oidc_plan` | policy | Statements from `github_plan_oidc_policy_statements` ([federation.md](federation.md)) |
| 8 | `oci_identity_policy.github_oidc_apply` | policy | Statements from `github_apply_oidc_policy_statements` |
| 9 | `oci_ons_notification_topic.operations` | topic `eventforge-operations` | Alerts sink |
| 10 | `oci_ons_subscription.operations_email` | EMAIL subscription | Requires the operator to confirm the subscription email |

**Stage split (mission M1-final, §5C):** resources 7 and 8 (the two GitHub workload policies) are
now behind `enable_workload_policies` (default **false**). Their statements constrain the
exchanged principal with draft claim keys (e.g. `github_environment`) that only the first live
token exchange can verify, so **Stage 1 applies exactly 8 creates** (1–6, 9, 10); **Stage 2**
flips the flag and adds the two policies (2 creates) only after the claim mapping is confirmed
live. `tests/ci/test-bootstrap-policy.sh` enforces the gate.

**Non-mutation confirmation ✅** — the bootstrap root declares none of: `oci_core_instance`,
`oci_mysql_mysql_db_system`, `oci_core_vcn`, `oci_core_subnet`, `oci_load_balancer_load_balancer`,
any `oci_core_security_list`/`oci_core_route_table`, or any compute resource. The preflight
`bootstrap-scope-allowlist` check enforces this allowlist automatically and fails on any new
resource type. Existing compute, MySQL, VCN/subnets, and load balancer are untouched; no public
ingress is created (the bootstrap root has no ingress concept at all).

## 2. Vault / customer-managed key dependency

- `state_bucket_kms_key_id` is a **required** variable; the bootstrap root does **not** create the
  key. The key must exist **before** `terraform apply` and must be in the same region as the bucket
  (`ap-hyderabad-1` — the tenancy home region, verified).
- **Live finding:** vault `rust-api-secrets` (`ocid1.vault.oc1.ap-hyderabad-1.gfvn7rbsaab4m.abuhsljrdq32j4pb5cwcaya2chgt7llct46eumxquvmt6uo3fkm4nm7loahq`, tenancy root, ACTIVE) contains one
  enabled key `rust-api-secret-key` (AES, SOFTWARE protection).
- **Recommendation (operator decision):** create a dedicated master key (for example
  `eventforge-tfstate-key`) in that vault rather than reusing the secrets key, so state encryption
  and secret encryption have independent key lifecycle and rotation. If `rust-api-secret-key` is
  reused instead, record that decision here.
- Permissions: the operator applying the root must be allowed to `use keys`; the
  `eventforge-objectstorage-kms` policy grants the Object Storage service its side. **Corrected in
  M1B.1.1:** the service subject is hyphenated — `Allow service objectstorage-${var.region} to use
  keys in compartment id ${var.kms_key_compartment_ocid} where target.key.id =
  '${var.state_bucket_kms_key_id}'` — per the [OCI Object Storage policy
  reference](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/objectstoragepolicyreference.htm);
  the earlier underscore form was incorrect. Key permissions are scoped to the **key's own
  compartment** via the new required `kms_key_compartment_ocid` variable (it may differ from the
  bucket compartment) and pinned to the exact key OCID. Terraform validates regional
  compatibility at plan time (`state_bucket_kms_key_id` must start with
  `ocid1.key.oc1.<region>.`), and `tests/ci/test-bootstrap-policy.sh` locks the statement form
  so neither defect can regress.
- Encryption validation: after apply, verify the bucket's `kms-key-id` equals the CMK OCID, list
  one state object's `kms-key-id`, and confirm the key is ENABLED — the preflight
  `post-bootstrap` mode performs this live ([state-recovery.md](state-recovery.md) §5).
- Rotation/loss procedures: rotation = create a new key version (object storage keeps reading the
  latest version); documented in [state-recovery.md](state-recovery.md). Losing the key without
  retaining a state backup makes the state permanently unreadable — the mandatory pre-apply state
  backup step exists for this reason.

## 3. Always Free resource consumption estimate (bootstrap only)

| Resource | Estimate | Notes |
| --- | --- | --- |
| Object Storage | 2 of unlimited buckets; ~0 GiB initially, grows with backups against the **20 GiB** Always Free allowance | State objects are KB–MB scale |
| Vault | 0 new vaults (reusing `rust-api-secrets`); +1 of **20** free master encryption keys if the dedicated key is created; key versions against the 150 free | Region already the home region |
| IAM | 1 dynamic group, 5 policies — free, effectively unlimited | |
| Notifications | 1 topic + 1 email subscription; ~0 of 1,000 free deliveries/month | Requires email confirmation |
| Monitoring/Budget | none in bootstrap (platform root adds alarms/budget later) | |
| Compute / MySQL / Load balancer | **0 new** — existing Always Free instances and MySQL.Free untouched | |

Bootstrap adds no billable resource if the tenancy stays within Always Free quotas.

## 4. Bootstrap state protection

The bootstrap root starts with **local state** (it creates the bucket it would later use). Local
state files are git-ignored; after apply the operator immediately migrates to the native backend
(`bootstrap/terraform.tfstate` key) and keeps a manual backup copy before migration — sequence in
[state-recovery.md](state-recovery.md) §2–3. The `moved` block for the policy rename is inert on
first apply (no prior state exists) and only matters if an older bootstrap state is migrated.

## 5. Required operator inputs (git-ignored, never committed)

`infra/bootstrap/terraform.auto.tfvars` from `terraform.tfvars.example`: tenancy/compartment OCIDs,
`region = "ap-hyderabad-1"`, `object_storage_namespace = axrq1dasyz3y` (verified live), the two VM
OCIDs (in `docs/acceptance/m1b/import-reconciliation.json`), `state_bucket_kms_key_id`, the
notification email, and the two policy statement sets from [federation.md](federation.md).
`scripts/acceptance/m1b-bootstrap-preflight.sh` checks for the file's presence without reading it.
