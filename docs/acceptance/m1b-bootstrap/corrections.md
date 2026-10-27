# M1B.1.1 — verified corrections before the first cloud mutation

Generated: 2026-10-27 · Each correction was verified against primary sources before being applied;
none of them was applied to live GitHub, OCI, or Cloudflare.

## 1. Object Storage → KMS policy service subject (P0)

- Defect: `infra/bootstrap/main.tf` scoped the Object Storage service policy with the underscore
  form `objectstorage_${var.region}` and the bucket compartment.
- Correction: the [OCI Object Storage policy
  reference](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/objectstoragepolicyreference.htm)
  uses the hyphenated subject `objectstorage-<location>`. The statement now reads
  `Allow service objectstorage-${var.region} to use keys in compartment id
  ${var.kms_key_compartment_ocid} where target.key.id = '${var.state_bucket_kms_key_id}'`.
- Also added: the required `kms_key_compartment_ocid` variable (key permissions scoped to the
  key's own compartment, which may differ from the bucket compartment), a plan-time regional
  compatibility validation (`state_bucket_kms_key_id` must start with `ocid1.key.oc1.<region>.`),
  and `tests/ci/test-bootstrap-policy.sh` to lock both forms.

## 2. Immutable GitHub OIDC subjects (P0)

- Change: all subject expectations now use GitHub's immutable numeric format — mandatory for all
  repositories since 2026-06-18 per the [GitHub changelog](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens)
  (the `@<id>` delimiter replaced the originally documented `-` delimiter in June 2026).
  `eswrops/EventForge` was created 2026-10-26, after the 2026-07-15 automatic cutover, so its
  tokens already use this format.
- Expected subjects:
  - `repo:eswrops@237514587/EventForge@1434990962:environment:production-plan`
  - `repo:eswrops@237514587/EventForge@1434990962:environment:production`
- Updated: `scripts/ci/inspect-oidc-claims.sh` (verified numeric constants + live REST drift
  detection), `scripts/ci/configure-oci-wif.sh` (required `repository_owner_id`/`repository_id`
  config fields), `docs/bootstrap.md`, federation/github-security documentation, and all OIDC
  fixtures — including new negative fixtures for legacy name-only subjects and wrong numeric IDs.
- Safety order: the first protected live claim inspection (checklist step 5) must confirm the
  exact subject **before** any OCI trust is configured.

## 3. Single-maintainer branch protection (P0)

- Change: the recommended current protection sets `required_approving_review_count: 0` with pull
  requests still mandatory, admin-enforced, force pushes/deletion blocked, and all four CI checks
  required — no deadlock for the sole maintainer and no direct pushes. The one-independent-
  approval configuration is retained as §5b of
  [github-security.md](github-security.md) for the moment a second eligible reviewer exists.
- Self-review hardening verified: the GITHUB_TOKEN cannot approve pull requests
  (`can_approve_pull_request_reviews: false`), enforced by the preflight `gh-token-permissions`
  check.

## 4. Preflight correctness fixes (P1)

- Environment protection rule detection now matches `required_reviewer` **and** `required_reviewers`
  (the observed API value has varied) and compares the exact reviewer IDs, requires exactly one
  deployment branch policy named `main`, and verifies the self-review prevention flag.
- Added the `gh-actions-allowlist` check (`allowed_actions == selected`).
- Added explicit `--mode pre-bootstrap` (default), `--mode post-bootstrap`, and `--mode
  pre-import`. Post-bootstrap expects exactly the authorized buckets (creation is not drift) and
  validates versioning plus the live CMK (key state ENABLED), instead of merely finding an active
  Vault. Pre-import permits only the reviewed mapped resource addresses, requires
  `prevent_destroy` on each, and fails if shared route/security resources are declared.
- Fixed a real false-negative in the token-permissions check: jq's `//` operator swallowed the
  boolean `false` of `can_approve_pull_request_reviews`.

## 5. Post-review interoperability corrections (2026-10-27, M1B.1.1 follow-up)

Confirmed by operator review of the merged M1B.1.1 code:

- **Environment creation command (P0).** The earlier `gh api -f/-F` form used dotted nested keys
  (sent as literal key names) and string-valued `wait_timer`. Replaced with a `jq -n` JSON body
  piped to `gh api --input -`, setting `wait_timer: 0` (integer),
  `prevent_self_review: false` (required for the single-operator approval model),
  the exact reviewer object, and the nested `deployment_branch_policy`. The preflight
  `gh-environment-*` check now also verifies `prevent_self_review` is not `true`.
- **KMS key-compartment input (P0).** The existing Vault lives in the **tenancy root**, which OCI
  addresses with the tenancy OCID — the earlier compartment-regex validation would have rejected
  the correct value. The validation now accepts `var.kms_key_compartment_ocid ==
  var.tenancy_ocid` or a child compartment OCID, and the policy location is built conditionally
  (`tenancy` vs `compartment id <ocid>`); both variants were plan-tested offline and the
  policy-string tests and preflight check were updated to lock the new form.
- **Numeric ID claim shape (P0).** GitHub has represented `repository_id` /
  `repository_owner_id` as JSON numbers and as digit strings at different times. The WIF helper
  now normalizes both sides with `tostring` before exact decimal comparison (`--arg`, not
  `--argjson`), and fixtures cover both shapes plus a string-encoded wrong ID. The claim-inspection
  script was already type-agnostic (`jq -r`); the protected live inspection remains authoritative
  for the actual token shape.
- **IAM draft tightening (P1).** The plan-identity statement that used `any {…}` (an OR that would
  have satisfied the policy on `request.principal.type` alone) now uses `all {…}` throughout, and
  the apply identity's `manage all-resources` was narrowed to the resource types the platform root
  actually manages (network-security-groups, load-balancers, alarms, usage-budgets) pending
  verification of exact resource-type names and claim keys during step-8 review.

## 6. `os object copy` source-bucket option (P0, found in first live execution 2026-10-27)

- Defect: `scripts/acceptance/oci-state-version-recovery.sh` invoked the version copy as
  `oci os object copy --source-bucket <bucket> …`. OCI CLI 3.95.1 (operator workstation, the
  only approved execution environment) has **no** `--source-bucket` option; the command aborts
  at argument parsing ("No such option '--source-bucket'. Did you mean
  '--source-object-name'?") before any API call, so the copy never started and nothing was
  written. The offline fixtures could not catch it because the stubbed `oci` accepts any
  well-formed argv — option-name validity against the real CLI is only checkable against
  `oci os object copy --help`, which is what the fix verified.
- Correction: the source bucket is carried by the command group's `[required]` `--bucket-name`
  option. `--source-version-id`, `--destination-*`, `--destination-object-if-none-match-e-tag`,
  and `--wait-for-state` were verified present in the live help and are unchanged. The same
  wrong option in the [state-recovery.md](state-recovery.md) §7 manual command was corrected.
- Regression guard: the offline fixtures now assert the copy line carries
  `--bucket-name <approved bucket>` and refuse any `--source-bucket` occurrence.
- Live record: the failure occurred during the first approved execution (package revision
  "OCI CLI CONTRACT FIX 1", RUN_ID `20261027T120000Z-m1live`) after STATE-LOCKING and
  STATE-CONTENTION had already PASSED; the script preserved its evidence directory and the
  used live-acceptance key stays retained for review per the package's §11 rollback boundary.
