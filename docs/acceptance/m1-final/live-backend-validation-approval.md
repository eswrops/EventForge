# Live backend validation — approval package (PREPARED, NOT EXECUTED)

Status: **HARDENED PACKAGE 2026-10-27, SAFETY PATCH 1 2026-10-27 — awaiting
explicit operator approval. Nothing in this package has been executed against
OCI.** Scope: live
verification of **STATE-LOCKING, STATE-CONTENTION, and STATE-RECOVERY** on
disposable keys only, plus read-only bucket/CMK verification. **IAM-DENIAL is
NOT covered by this package** — it is deferred to the federation phase (§9);
no PASS may be recorded for it from this package. No production state key is
touched: every write this package can perform lands under
`validation/live-acceptance-<RUN_ID>/` or `validation/restore-test-<RUN_ID>/`.

## 1. Package integrity

This package is immutable once merged: the operator verifies the exact bytes
before running anything and transcribes the merge commit into the §12 record.

- Base package: PR #22 (squash-merged as `a4e0904a69bad0e16387fafb74b31c0d68ec976a`).
- Safety patch 1: the focused PR that introduced the object-absence,
  copy-race, and precondition hardening (squash-merged into `main` through
  branch protection).
- Merge commit: `938ff899b68367fb408a17a6d1a8eea758d62894`
  (verify: `git log --format='%H %s' -1 938ff89`)
- Content hashes (sha256), verified before execution:

| File | sha256 |
| --- | --- |
| `scripts/ci/lib-oci-validation.sh` | `9e03f6f90d0814b959201403d622f65acabae7f9c432f3573ad36432b4958f7b` |
| `scripts/ci/verify-oci-backend.sh` | `f069bfea81c514a18f83fb02208eac372fce298268d50feeebe247287582bcca` |
| `scripts/ci/verify-oci-backend-denied.sh` | `aa2130bec68fbc38b51a5258c3ff6f6bc8983c6d2c6bea953f60ffc551056512` |
| `scripts/acceptance/oci-state-version-recovery.sh` | `70db26949c34ce454939a54469d69d5f9b672feadd79e7baa1562a3be6b15f23` |

- Executable: **Terraform v1.12.2 exactly**, selected via `TERRAFORM_BIN`
  (`/Users/eswr/tools/terraform/1.12.2/terraform`). The scripts refuse any
  other binary or version and never fall back to `PATH`.
- Regression suite: `tests/ci/test-oci-live-validation-guards.sh` (offline,
  stubbed `terraform`/`oci`) covers wrong bucket/namespace, unauthorized key
  prefixes, reused keys (including keys whose current object is gone but
  whose previous versions or delete markers remain), failed listings (403,
  500, pagination failure, malformed responses — never treated as absence),
  bucket precondition violations (public access, versioning off, wrong or
  disabled CMK, unreadable metadata), unexpected Terraform versions, wrong
  authentication profiles, background-apply failure, lock-contention failure
  (including an unrelated error that merely contains the word "lock"),
  interrupted execution, incomplete asynchronous copies, conditional-copy
  rejection, and concurrent destination creation.

## 2. Approved constants, derived keys, and identity

| Input | Approved value (fail-closed) |
| --- | --- |
| `TF_STATE_BUCKET` | `eventforge-tfstate-prod` |
| `OCI_OBJECT_STORAGE_NAMESPACE` | `axrq1dasyz3y` |
| `OCI_REGION` | `ap-hyderabad-1` |
| `RUN_ID` (required) | pattern `^[A-Za-z0-9][A-Za-z0-9-]{2,63}$` |
| State key (derived) | `validation/live-acceptance-<RUN_ID>/terraform.tfstate` |
| Lock key (derived) | `<state key>.lock` |
| Restore key (derived) | `validation/restore-test-<RUN_ID>/terraform.tfstate` |
| Workspace | `default` only |
| `TF_VALIDATION_EXPECTED_KMS_KEY_ID` | the exact state CMK OCID (operator transcribes it from the gitignored tfvars / Phase-2 record) |

The scripts fail closed when any supplied value differs from the above, when
`TF_BACKEND_VALIDATION_KEY` does not equal the derived state key exactly, when
the destination state key or its lock key cannot be proven absent, and for the
`bootstrap/`, `platform/`, `frontend/` prefixes unconditionally (never probe
production keys). Before any mutation they verify, read-only: the
authenticated namespace is the approved one, the bucket is `NoPublicAccess`,
versioning `Enabled`, bound to the exact expected CMK, and that CMK is still
`ENABLED` — an inability to complete any of these checks aborts the run. Authentication is never implied: `TF_OCI_AUTH` must be
exactly `APIKey` (with an explicit `TF_OCI_PROFILE`, which alone selects the
backend `config_file_profile` — `OCI_CLI_PROFILE` is never relied on) or
`ResourcePrincipal` (with the RPST environment from `configure-oci-wif.sh`).

Identity:

- **Option A (approved here, recommended):** the operator workstation's
  verified OCI CLI **API-key** `DEFAULT` profile — the same administrator
  principal already approved for bootstrap work (`TF_OCI_AUTH=APIKey`,
  `TF_OCI_PROFILE=DEFAULT`). No new principal, no IAM change.
- **Option B (post-federation only):** the CI runner's Resource Principal via
  RPST; the `oci-backend-validation` workflow is pre-wired for it and takes
  `run_id` as a dispatch input.

## 3. Concrete execution commands (Option A, operator workstation)

```bash
cd /Users/eswr/code/rust/EventForge && git fetch origin main && git checkout <merge commit from §1>

export RUN_ID="20261027T120000Z-m1live"          # concrete RUN_ID of this approval
export TF_STATE_BUCKET="eventforge-tfstate-prod"
export OCI_OBJECT_STORAGE_NAMESPACE="axrq1dasyz3y"
export OCI_REGION="ap-hyderabad-1"
export TERRAFORM_BIN="/Users/eswr/tools/terraform/1.12.2/terraform"
export TF_OCI_AUTH="APIKey"
export TF_OCI_PROFILE="DEFAULT"                  # approved operator write identity
# Transcribe the EXACT state CMK OCID from the gitignored tfvars / Phase-2
# record; the scripts verify the bucket is bound to it and that it is ENABLED:
export TF_VALIDATION_EXPECTED_KMS_KEY_ID="<ocid1.key.oc1.ap-hyderabad-1...>"

# 0. Read-only preconditions: approved bucket coordinates, no active locks
#    anywhere near the package prefixes, key absent (scripts re-verify all of
#    this and fail closed, but record the evidence):
oci os bucket get --bucket-name eventforge-tfstate-prod \
  | jq '.data."kms-key-id", .data."public-access-type", .data."versioning"'
oci os object list --bucket-name eventforge-tfstate-prod \
  --prefix "validation/live-acceptance-${RUN_ID}/" --all | jq '.data[].name'
oci os object list-object-versions --bucket-name eventforge-tfstate-prod \
  --prefix "validation/live-acceptance-${RUN_ID}/" --all | jq '.data[].name'

# 1. STATE-LOCKING + STATE-CONTENTION (LIVE MUTATION, confined to the state
#    and lock keys above): init, isolated apply, held-lock contention (a
#    concurrent plan must fail WITH a lock error), state read-back, destroy,
#    and post-destroy lock re-acquisition:
bash scripts/ci/verify-oci-backend.sh

# 2. STATE-RECOVERY (LIVE MUTATION, confined to the restore-test key): lists
#    real object versions, selects the oldest NONCURRENT version, waits for
#    the asynchronous copy into validation/restore-test-<RUN_ID>/, verifies
#    lineage/serial equality and Terraform readability:
bash scripts/acceptance/oci-state-version-recovery.sh

# 3. Read-only CMK verification of what step 1 wrote:
oci os object head --bucket-name eventforge-tfstate-prod \
  --name "validation/live-acceptance-${RUN_ID}/terraform.tfstate" \
  | jq '."kms-key-id", ."version-id"'
```

Every command aborts without a matching approved environment; no manual
backend.hcl edit exists anymore.

## 4. Precise object operations (audited, offline-tested)

`verify-oci-backend.sh`:

1. `os ns get`, `os bucket get`, `kms management key get` — the
   authenticated namespace, `NoPublicAccess`, `versioning Enabled`, the exact
   expected CMK bound and `ENABLED`; any failure or malformed response aborts
   before any mutation.
2. For EACH of the state key and the lock key: `os object list --prefix <key>
   --all` AND `os object list-object-versions --prefix <key> --all` must
   SUCCEED, and the EXACT object name must appear in neither (no current
   object, previous version, or delete marker). A failed listing is
   authorization/authentication/network/pagination trouble and is never
   treated as absence.
3. `terraform init` against the derived key (no state write at init).
4. `workspace show` must return `default` before any apply.
5. Background `terraform apply` (holds the lock ~15 s): writes the state
   object and transient `<key>.lock` objects; the script polls `os object
   head` on the lock key and records the exact observed lock object name.
6. Concurrent `terraform plan -lock-timeout=1s` must fail with the real
   Terraform state-lock error ("Error acquiring the state lock"); an
   unrelated error that merely contains the word "lock" fails the gate.
7. `terraform state pull` must return the probe resource.
8. `terraform destroy` empties the state; a post-destroy plan must re-acquire
   the released lock (deliberately not applied).

`oci-state-version-recovery.sh`: the same preconditions as above, then
`os object head` (source present, current version id),
`os object list-object-versions --all` (must succeed; malformed responses
abort), `os object list --all` + `os object list-object-versions --all` on the
restore key (absence proof), `os object copy --source-version-id <validated
vid> --destination-object-if-none-match-e-tag '*' --wait-for-state COMPLETED`
(single conditional write to the restore-test key; the service rejects it if
a concurrent writer created the destination), `os object head` + two
`os object get` (read-back; the restored object must be BYTE-IDENTICAL to the
complete selected source-version snapshot via `cmp`, with equal lineage and
serial), then scratch `terraform init` + `state pull` against the restore key
(reads only). The selected source version is re-confirmed to belong to the
exact RUN_ID state key before the copy.

Neither script contains any `os object delete`/`bulk-delete`/`put`, no
`force-unlock`, and no `state push`; the offline tests assert this.

## 5. Expected writes and deletes

| Object | Writes | Deletes |
| --- | --- | --- |
| `validation/live-acceptance-<RUN_ID>/terraform.tfstate` | ~2–4 versioned snapshots (apply, destroy-empty) | none (retained for review) |
| `validation/live-acceptance-<RUN_ID>/terraform.tfstate.lock` | 5–8 transient lock infos | 5–8 (each by Terraform's normal unlock) |
| `validation/restore-test-<RUN_ID>/terraform.tfstate` | 1 (the waited version copy) | none (retained for review) |

Anything outside these three keys is a stop condition (§7).

## 6. Process, failure, and evidence handling

- The background apply can never outlive the script unnoticed: `EXIT`, `INT`,
  and `TERM` are trapped; the child is reaped (TERM, then KILL after 10 s) and
  any surviving child forces a non-zero exit.
- On any unexpected failure the temporary Terraform root and all logs are
  MOVED into a protected evidence directory (`TF_VALIDATION_EVIDENCE_DIR`,
  default `${TMPDIR:-/tmp}/eventforge-validation-evidence/<RUN_ID>-<stamp>`,
  mode `0700`) and its path is printed. The scripts never delete an active or
  failed Terraform working directory and never remove a lock object.
- A surviving lock is reported with its exact object name and a pointer to the
  separately approved deletion procedure (§10). Denial-probe failures preserve
  their init log the same way.

## 7. Stop conditions

Abort immediately (the scripts fail loudly and preserve evidence) and stop for
incident review if any of: an object appears outside the three permitted keys;
a lock object remains after the script reports release (wait 120 s, re-check,
do NOT force-unlock); any command touches a `bootstrap/`, `platform/`, or
`frontend/` key; the bucket reports `public-access-type` other than
`NoPublicAccess`, versioning other than `Enabled`, a changed `kms-key-id`,
or a disabled/failed CMK lookup; any absence-proof listing fails or returns a
malformed response (never treated as absence); the concurrent plan fails for a
non-lock reason; any guard refuses an input (bucket/namespace/region/key/
workspace/binary/auth/expected-CMK).

## 8. Version-recovery procedure (corrected)

The previously documented command `oci os object list-versions` **does not
exist**. The supported CLI command is `oci os object list-object-versions`,
whose response is `{"data": [ ... ], "prefixes": [ ... ]}` with items carrying
`name`, `version-id`, `is-delete-marker`, `time-created`, `size`, and
`storage-tier` — there is **no `is-current` field**; the current version id
comes from `oci os object head` on the object. The committed
`oci-state-version-recovery.sh` implements the corrected procedure:

1. Require the source to be exactly this run's live-acceptance state key
   (present) and read its current version id from `object head`.
2. List versions with `list-object-versions`; keep only entries for that name
   with a non-null `version-id`, `is-delete-marker` false, and a version id
   different from the current one; order by `time-created`.
3. Select a specific version: `TF_RESTORE_VERSION_ID` if provided (validated
   against the noncurrent set, current versions refused), otherwise the oldest
   noncurrent version.
4. Confirm the exact destination `validation/restore-test-<RUN_ID>/terraform.tfstate`
   is absent.
5. Copy that version EXCLUSIVELY to the restore-test key with
   `--source-version-id`, `--destination-object-if-none-match-e-tag '*'`
   (the service rejects the copy if a concurrent writer created the
   destination after the absence check), and `--wait-for-state COMPLETED`
   (the copy is asynchronous; an incomplete work request fails the script),
   then re-HEAD the destination to prove the object actually landed.
6. Verify the restored state: `os object get` of both source version and
   destination, requiring the restored object to be BYTE-IDENTICAL to the
   complete selected source-version snapshot (`cmp`) with identical lineage
   and serial, then scratch `terraform init` + `state pull` against the
   restore key with the same equality check.
7. Never restore onto the production bootstrap key — or any production key;
   a production recovery remains a separately approved incident procedure
   ([state-recovery.md §7](../../m1b-bootstrap/state-recovery.md)).

## 9. IAM-DENIAL: deferred to the federation phase

There is currently no approved underprivileged principal, and creating an IAM
user or API key for the probe is an IAM change that is **not approved by this
package**. Therefore:

- `scripts/ci/verify-oci-backend-denied.sh` stays committed for the federation
  phase, hardened: it now requires the same RUN_ID confinement, explicit
  `TF_OCI_AUTH`, an explicitly selected profile, and **refuses the privileged
  `DEFAULT` profile outright**; it proves it wrote nothing by comparing the
  probe key's presence before and after the denied init.
- **IAM-DENIAL must NOT be marked PASS** from administrator-profile testing,
  from mock/stub runs, or from any run under the approved operator identity.
  It stays NOT_RUN until an explicitly underprivileged identity exists in the
  federation phase and the probe's redacted denial is recorded.
- Do not run the denial script under Option A identity "to see it work".

## 10. Cleanup approval boundary

- Both validation prefixes are retained after the run as audit artifacts.
- Deleting them (including noncurrent versions) is a mutation OUTSIDE this
  approval: it requires a second explicit operator approval naming the
  concrete RUN_ID, e.g.
  `oci os object bulk-delete --bucket-name eventforge-tfstate-prod --prefix 'validation/live-acceptance-<RUN_ID>/' --force`
  (and the restore-test prefix), only after the §12 record is complete.
- Manual deletion of an ORPHANED lock object requires its own scoped approval
  naming the exact object (`validation/live-acceptance-<RUN_ID>/terraform.tfstate.lock`),
  after positively verifying age/owner via `os object head` — the scripts
  never remove locks themselves, and `terraform force-unlock` remains
  prohibited.

## 11. Rollback boundaries

- Failed apply/destroy on the disposable root: preserve the evidence
  directory; a re-run uses a FRESH RUN_ID (the used keys must stay untouched
  for review). Never `state push -force`, never `force-unlock`.
- Wrong object anywhere: stop, preserve versions, open an incident approval;
  the versioned bucket allows copying the prior version back per
  [state-recovery.md §7](../../m1b-bootstrap/state-recovery.md) with a fresh
  manual backup first.
- This package touches no IAM, federation, networking, compute, MySQL, load
  balancer, or Cloudflare resource; no rollback outside Object Storage is
  possible from this package.

## 12. Execution record (to be filled at execution time, separate approval)

- [ ] Merge commit (from §1):
- [ ] Script hashes verified (`shasum -a 256 -c` style check performed):
- [ ] RUN_ID used:
- [ ] Operator:
- [ ] Auth mode/profile used:
- [ ] STATE-LOCKING output retained at:
- [ ] Observed lock object name:
- [ ] Version ids observed:
- [ ] STATE-RECOVERY evidence retained at:
- [ ] TF_VALIDATION_EXPECTED_KMS_KEY_ID used (transcribed from tfvars):
- [ ] Bucket preconditions verified live (NoPublicAccess / versioning / CMK bound + ENABLED):
- [ ] KMS ids confirmed:
- [ ] IAM-DENIAL: NOT_RUN (deferred to federation phase)
- [ ] Cleanup performed (ids deleted, when; separate approval reference):
