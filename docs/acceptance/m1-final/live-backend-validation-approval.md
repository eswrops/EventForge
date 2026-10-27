# Live backend validation — approval package (PREPARED, NOT EXECUTED)

Status: **HARDENED PACKAGE 2026-10-27 — awaiting explicit operator approval.
Nothing in this package has been executed against OCI.** Scope: live
verification of **STATE-LOCKING, STATE-CONTENTION, and STATE-RECOVERY** on
disposable keys only, plus read-only bucket/CMK verification. **IAM-DENIAL is
NOT covered by this package** — it is deferred to the federation phase (§9);
no PASS may be recorded for it from this package. No production state key is
touched: every write this package can perform lands under
`validation/live-acceptance-<RUN_ID>/` or `validation/restore-test-<RUN_ID>/`.

## 1. Package integrity

This package is immutable once merged: the operator verifies the exact bytes
before running anything and transcribes the merge commit into the §12 record.

- PR: the squash merge of the PR that introduced this file into `main`
  (head branch `m1-final/live-validation-hardening`). Transcribe the exact
  merge commit at execution time with:
  `git log --format='%H %s' --grep='live-validation-hardening' -1`
- Content hashes (sha256), verified before execution:

| File | sha256 |
| --- | --- |
| `scripts/ci/lib-oci-validation.sh` | `98f3e2c47a52d3d4797f58c93fad25b95f894efa7a9d83e8e826ce866cbf04a7` |
| `scripts/ci/verify-oci-backend.sh` | `d17e8d5a95ec368c9e849d1452b86896ed52ea9920174f4c055c45ddd4c8d4ff` |
| `scripts/ci/verify-oci-backend-denied.sh` | `496b014d77be609c70b59d52650a62a9f326e9e2319d4477d8c693cb0462b001` |
| `scripts/acceptance/oci-state-version-recovery.sh` | `bd8d5d45b96d38ca9d42a5c4a7f4f518d7c7cd4653ad671edae1a8a5e14de078` |

- Executable: **Terraform v1.12.2 exactly**, selected via `TERRAFORM_BIN`
  (`/Users/eswr/tools/terraform/1.12.2/terraform`). The scripts refuse any
  other binary or version and never fall back to `PATH`.
- Regression suite: `tests/ci/test-oci-live-validation-guards.sh` (offline,
  stubbed `terraform`/`oci`) covers wrong bucket/namespace, unauthorized key
  prefixes, reused keys, unexpected Terraform versions, wrong authentication
  profiles, background-apply failure, lock-contention failure, interrupted
  execution, and incomplete asynchronous copies.

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

The scripts fail closed when any supplied value differs from the above, when
`TF_BACKEND_VALIDATION_KEY` does not equal the derived state key exactly, when
the destination state key or its lock key already exists, and for the
`bootstrap/`, `platform/`, `frontend/` prefixes unconditionally (never probe
production keys). Authentication is never implied: `TF_OCI_AUTH` must be
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

# 0. Read-only preconditions: approved bucket coordinates, no active locks
#    anywhere near the package prefixes, key absent (scripts re-verify all of
#    this and fail closed, but record the evidence):
oci os bucket get --bucket-name eventforge-tfstate-prod \
  | jq '.data."kms-key-id", .data."public-access-type", .data."versioning"'
oci os object list --bucket-name eventforge-tfstate-prod \
  --prefix "validation/live-acceptance-${RUN_ID}/" | jq '.data[].name'

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

1. `os object head` state key → must be ABSENT; `os object head` lock key →
   must be ABSENT (any presence aborts before any mutation).
2. `terraform init` against the derived key (no state write at init).
3. `workspace show` must return `default` before any apply.
4. Background `terraform apply` (holds the lock ~15 s): writes the state
   object and transient `<key>.lock` objects; the script polls `os object
   head` on the lock key and records the exact observed lock object name.
5. Concurrent `terraform plan -lock-timeout=1s` must fail with a lock error.
6. `terraform state pull` must return the probe resource.
7. `terraform destroy` empties the state; a post-destroy plan must re-acquire
   the released lock (deliberately not applied).

`oci-state-version-recovery.sh`: `os object head` (source present, current
version id), `os object list-object-versions` (read), `os object head`
(destination ABSENT), `os object copy --source-version-id <vid> --wait-for-state
COMPLETED` (single write to the restore-test key), `os object head` + two
`os object get` (read-back and lineage/serial comparison), then scratch
`terraform init` + `state pull` against the restore key (reads only).

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
`NoPublicAccess` or a changed `kms-key-id`; the concurrent plan fails for a
non-lock reason; any guard refuses an input (bucket/namespace/region/key/
workspace/binary/auth).

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
   `--source-version-id` and `--wait-for-state COMPLETED` (the copy is
   asynchronous; an incomplete work request fails the script), then re-HEAD
   the destination to prove the object actually landed.
6. Verify the restored state: `os object get` of both source version and
   destination, requiring a valid snapshot (`lineage`, numeric `serial`,
   `terraform_version`) with identical lineage and serial, then scratch
   `terraform init` + `state pull` against the restore key with the same
   equality check.
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
- [ ] KMS ids confirmed:
- [ ] IAM-DENIAL: NOT_RUN (deferred to federation phase)
- [ ] Cleanup performed (ids deleted, when; separate approval reference):
