# Live backend validation — approval package (PREPARED, NOT EXECUTED)

Status: **PREPARED 2026-10-27 — awaiting explicit operator approval. Nothing in
this package has been executed against OCI.** Scope: live verification of
STATE-LOCKING, STATE-CONTENTION, STATE-RECOVERY, IAM-DENIAL on disposable keys
only, plus read-only bucket/CMK verification. No production state key is read
beyond read-only `state pull`-free inspection (nothing in this package touches
`bootstrap/terraform.tfstate` at all), no IAM/federation change, no
infrastructure resource creation.

Prerequisite status: **OCI federation NOT_CONFIGURED** — the RPST
(Resource Principal Session Token) environment that
`scripts/ci/configure-oci-wif.sh` exports does not exist yet, and that script
itself performs federation/IAM changes and is **out of scope** here. Option A
below therefore runs on the operator workstation with the verified API-key
profile (as already documented in
[state-recovery.md §1](../../m1b-bootstrap/state-recovery.md)); Option B is the
CI ResourcePrincipal variant for after the federation phase.

## 1. What the existing scripts actually do (audited)

`scripts/ci/verify-oci-backend.sh` — **this is a LIVE MUTATION**:

- Writes a throwaway root (`terraform_data.lock_probe` with a 15 s
  `local-exec` sleep) in a temp dir — no OCI infrastructure resource, but a
  real `terraform apply -auto-approve` and a real state write.
- Object writes against the bucket, all under one disposable key
  `validation/<UTC timestamp>-<pid>/terraform.tfstate` (override:
  `TF_BACKEND_VALIDATION_KEY`): several versioned state snapshots (init-free
  path skips the empty-state bootstrap; apply/destroy each persist) and
  transient lock objects at `<key>.lock` (created and deleted per Terraform
  operation: init/apply/plan/state-pull/destroy ≈ 5–8 lock cycles).
- Cleanup: `terraform destroy -auto-approve` empties the state; the state
  object and its noncurrent versions are **deliberately retained** for
  operator review; lock objects are deleted by normal unlocks. The post-destroy
  plan is not applied. Local temp dir removed on exit.
- Exit semantics: fails if the concurrent plan does not fail **with a lock
  error**, if the state cannot be read back, or if the post-destroy lock cannot
  be acquired.

`scripts/ci/verify-oci-backend-denied.sh` — read-only:

- Runs `terraform init` against the disposable key with a deliberately
  underprivileged identity and requires an authorization-denial failure.
  On both the expected and the unexpected path it writes **no** object
  (backend init of an absent default-workspace key performs no write; if init
  unexpectedly succeeds the script fails loudly and still writes nothing).

## 2. Option A (recommended): operator workstation, API-key identity

One-line deviation from the committed script (its `auth` is hardcoded to
`ResourcePrincipal`): before running, apply this exact edit inside the script's
generated `backend.hcl` heredoc — approved as part of this package:

```diff
-auth      = "ResourcePrincipal"
+auth      = "APIKey"
+config_file_profile = "DEFAULT"
```

(Or, preferred, an approved follow-up commit adding
`TF_OCI_AUTH=${TF_OCI_AUTH:-ResourcePrincipal}` + optional
`config_file_profile` passthrough so no manual edit is needed; that script
change is itself the first item under this approval.)

### Exact commands (run from the EventForge repo, operator workstation)

```bash
# 0. Preconditions (all read-only): no active lock objects, bucket private/
#    versioned/CMK-bound, key absent
oci os object list --bucket-name eventforge-tfstate-prod --prefix validation/live-acceptance- | jq '.data[].name'
oci os bucket get --bucket-name eventforge-tfstate-prod | jq '.data."kms-key-id", .data."public-access-type", .data."versioning"'
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-manual"
export TF_BACKEND_VALIDATION_KEY="validation/live-acceptance-${RUN_ID}/terraform.tfstate"
export TF_STATE_BUCKET=eventforge-tfstate-prod
export OCI_OBJECT_STORAGE_NAMESPACE=axrq1dasyz3y
export OCI_REGION=ap-hyderabad-1
export TERRAFORM_BIN=/Users/eswr/tools/terraform/1.12.2/terraform   # informational; script uses PATH

# 1. Native backend initialization + isolated write/read + lock contention +
#    release/reacquisition (LIVE MUTATION — see §1)
bash scripts/ci/verify-oci-backend.sh   # with the §2 auth edit applied
#    → record full stdout; note the retained validation key it prints

# 2. Exact lock object naming (read-only, run while step 1's first apply is
#    inside its 15 s sleep — needs a second terminal)
oci os object list --bucket-name eventforge-tfstate-prod \
  --prefix "validation/live-acceptance-${RUN_ID}/" | jq '.data[].name'
#    expect: validation/live-acceptance-<RUN_ID>/terraform.tfstate
#            validation/live-acceptance-<RUN_ID>/terraform.tfstate.lock

# 3. Multiple object versions + scratch-key version restoration (LIVE MUTATION
#    confined to validation/ keys)
oci os object list-versions --bucket-name eventforge-tfstate-prod \
  --prefix "validation/live-acceptance-${RUN_ID}/" | \
  jq -r '.data[] | select(."version-id" != null) | ."name", ."version-id"'
# restore the OLDEST state version onto a scratch key (never the live one):
oci os object copy --source-bucket eventforge-tfstate-prod \
  --source-object-name "validation/live-acceptance-${RUN_ID}/terraform.tfstate" \
  --source-version-id <oldest-version-id> \
  --destination-bucket eventforge-tfstate-prod \
  --destination-object-name "validation/restore-test-${RUN_ID}/terraform.tfstate" \
  --destination-region ap-hyderabad-1
# then a scratch backend init + `state pull` against the scratch key must
# succeed (same auth edit; key = validation/restore-test-${RUN_ID}/terraform.tfstate)

# 4. Underprivileged identity denial (read-only probe; identity in §3)
TF_BACKEND_VALIDATION_KEY="validation/live-acceptance-${RUN_ID}/terraform.tfstate" \
  bash scripts/ci/verify-oci-backend-denied.sh
#    → record the redacted denial (truncate any OCID/claim detail before storing)

# 5. CMK encryption verification (read-only)
oci os bucket get --bucket-name eventforge-tfstate-prod | jq '.data."kms-key-id"'
oci os object head --bucket-name eventforge-tfstate-prod \
  --name "validation/live-acceptance-${RUN_ID}/terraform.tfstate" | jq '."kms-key-id", ."version-id"'
```

### Identity used

- Option A: the operator's verified OCI CLI **API-key** `DEFAULT` profile (the
  same administrator principal already approved for bootstrap work). No new
  principal, no policy change.
- Option B (post-federation): the CI runner's Resource Principal via RPST,
  exactly as the committed scripts assume.

### Target bucket and permitted key prefixes

- Bucket: `eventforge-tfstate-prod` (private, versioned, CMK-bound).
- Permitted write/delete prefixes — nothing outside these may be touched:
  - `validation/live-acceptance-<RUN_ID>/` (state + lock objects)
  - `validation/restore-test-<RUN_ID>/` (version-restore scratch)
- Explicitly forbidden: `bootstrap/`, `platform/`, `frontend/`, any
  `*.tflock`/lock object outside the prefixes above, any bucket/policy/IAM
  object.

### Expected object writes/deletions

| Object | Writes | Deletes |
| --- | --- | --- |
| `validation/live-acceptance-<RUN_ID>/terraform.tfstate` | ~2–4 versioned snapshots (apply, destroy-empty) | none (retained for review) |
| `validation/live-acceptance-<RUN_ID>/terraform.tfstate.lock` | 5–8 transient lock infos | 5–8 (each on unlock) |
| `validation/restore-test-<RUN_ID>/terraform.tfstate` | 1 (the version copy) | none (retained for review) |

### Lock behavior

- Step 1 holds the state lock ~15 s (local-exec sleep) while a concurrent
  `plan -lock-timeout=1s` must fail with a lock error naming the holder
  ("state-lock probe" style operation info), then verifies release by
  reacquiring. Lock objects use the `<state-key>.lock` suffix — record the
  exact name observed (it finalizes the federation policy's
  `target.object.name matches /.*lock.*/i` pattern).

### Maximum duration and cost assumptions

- Wall clock: ≤ 10 minutes for steps 1–5 combined (15 s deliberate hold
  dominates; init/apply/destroy/plans ≈ 10–60 s each).
- Cost: a few tens of KB of Object Storage storage on versioned objects for
  the retention window; ~40–60 Class A/B requests; no compute, no networking,
  no license cost. Effectively $0.

### Cleanup policy

- Step 1 retains its key intentionally for operator review (post-destroy state
  is empty; retention is the audit artifact).
- After operator review (same session or later, second explicit approval
  recommended): delete the two prefixes and their noncurrent versions:
  `oci os object bulk-delete --bucket-name eventforge-tfstate-prod --prefix 'validation/live-acceptance-<RUN_ID>/' --force` (and the restore-test prefix),
  or per-object deletes of each version id. Deleting these objects is itself a
  mutation — it is part of this approval only when the operator re-issues it
  with the concrete RUN_ID.

### Stop conditions

Abort immediately (Ctrl-C; scripts fail loudly) and stop for incident review if
any of: an unexpected object appears outside the two permitted prefixes; a lock
object remains after the script reports release (wait 120 s, re-check; do NOT
force-unlock); any command touches a production key (`bootstrap/`,
`platform/`, `frontend/` prefixes); the bucket reports `public-access-type`
other than `NoPublicAccess` or a changed `kms-key-id`; the concurrent plan
fails for a non-lock reason.

### Recovery instructions

- Failed apply/destroy on the disposable root: the local temp dir holds the
  working dir; re-run `terraform destroy` against the same
  `TF_BACKEND_VALIDATION_KEY` from a fresh temp dir with the same backend.hcl.
  Never `state push -force`, never `force-unlock`.
- Stuck lock on a `validation/` key: verify age/owner via
  `oci os object head` on the lock object, then (approval already covered by
  the disposable-key rule in state-recovery.md §9) delete that lock object by
  exact name and re-run.
- Any production-key anomaly: stop, preserve object versions (do not delete),
  open an incident approval. Versioned bucket means any erroneous write can be
  reverted by copying the prior version per state-recovery.md §7 — with a
  fresh manual backup taken first.

## 3. Underprivileged identity for the IAM-denial probe

The denial probe needs an identity that can authenticate but must fail
authorization on the state bucket. Until federation exists there is no spare
resource principal; the honest options are:

1. **Preferred (defer):** run `verify-oci-backend-denied.sh` with an explicitly
   underprivileged resource principal as part of the federation phase, where
   such a principal is created and its denial is recorded redacted (this is
   already the plan in state-recovery.md §5).
2. **Alternative (this approval):** create a throwaway API key on a
   minimal IAM user with **no** policy statements touching the state bucket,
   put it in a scratch OCI CLI profile (e.g. `denied-probe`), run the script
   with `OCI_CLI_PROFILE=denied-probe` after the same auth edit, then disable
  /delete that key. Creating that user/key is an IAM change and therefore
   **explicitly excluded from this package's approval** — Option 1 is the
   default unless the operator separately approves the throwaway identity.

## 4. Execution record (to be filled at execution time, separate approval)

- [ ] RUN_ID:
- [ ] Operator:
- [ ] Auth mode used (A/B):
- [ ] Step 1 output retained at:
- [ ] Observed lock object name:
- [ ] Version ids observed:
- [ ] Denial evidence (redacted):
- [ ] KMS ids confirmed:
- [ ] Cleanup performed (ids deleted, when):
