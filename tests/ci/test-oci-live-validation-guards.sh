#!/usr/bin/env bash
set -euo pipefail

# Offline regression suite for the hardened live OCI validation scripts.
# Every live mutation path is exercised against stub `terraform` and `oci`
# binaries that simulate lock objects, versioned objects, and work-request
# behavior, so no network call and no real bucket is ever touched.

# shellcheck disable=SC2034  # MOCK_* variables are consumed by the stubs.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verify_script="$repo_root/scripts/ci/verify-oci-backend.sh"
denied_script="$repo_root/scripts/ci/verify-oci-backend-denied.sh"
recovery_script="$repo_root/scripts/acceptance/oci-state-version-recovery.sh"

bash -n "$verify_script" "$denied_script" "$recovery_script" \
  "$repo_root/scripts/ci/lib-oci-validation.sh"

tmp="$(mktemp -d)"
trap '[[ -n "${TEST_KEEP_TMP:-}" ]] || rm -rf "$tmp"' EXIT

approved_bucket="eventforge-tfstate-prod"
run_id="validation-run-1"
state_key="validation/live-acceptance-${run_id}/terraform.tfstate"
lock_key="${state_key}.lock"
restore_key="validation/restore-test-${run_id}/terraform.tfstate"

# ---------------------------------------------------------------- stubs ------
stub_dir="$tmp/stubs"
mkdir -p "$stub_dir"

cat > "$stub_dir/terraform" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "terraform $*" >> "${MOCK_TF_LOG:?}"
chdir=""
backend_cfg=""
cmd=""
for a in "$@"; do
  case "$a" in
    -chdir=*) chdir="${a#-chdir=}";;
    -backend-config=*) backend_cfg="${a#-backend-config=}";;
    -*) ;;
    *) if [[ -z "$cmd" ]]; then cmd="$a"; fi;;
  esac
done
if [[ "$cmd" == "version" ]]; then
  echo "Terraform v${MOCK_TF_VERSION:-1.12.2}"
  echo "on ${MOCK_TF_PLATFORM:-linux_amd64}"
  exit 0
fi
if [[ "$cmd" == "workspace" ]]; then
  echo "${MOCK_TF_WORKSPACE:-default}"
  exit 0
fi
if [[ -n "$backend_cfg" ]]; then
  if [[ "$backend_cfg" != /* ]]; then
    backend_cfg="$chdir/$backend_cfg"
  fi
fi
if [[ "$cmd" == "init" ]]; then
  if [[ -n "$backend_cfg" ]]; then
    cp "$backend_cfg" "${MOCK_TF_CAPTURE_DIR:?}/backend.hcl"
    key="$(sed -nE 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$backend_cfg")"
    printf '%s' "$key" > "${MOCK_TF_CAPTURE_DIR:?}/state-key"
  fi
  if [[ "${MOCK_INIT_WRITES:-0}" == "1" ]]; then
    mkdir -p "${MOCK_BUCKET_DIR:?}/$(dirname "${key:?}")"
    printf 'premature write' > "${MOCK_BUCKET_DIR:?}/${key:?}"
  fi
  if [[ "${MOCK_INIT_FAIL:-0}" == "1" ]]; then
    echo "${MOCK_INIT_FAIL_MSG:-Error: NotAuthorizedOrNotFound: Authorization failed or requested resource not found.}"
    exit 1
  fi
  echo "Terraform has been successfully initialized!"
  exit 0
fi
key="$(cat "${MOCK_TF_CAPTURE_DIR:?}/state-key" 2>/dev/null || true)"
if [[ "$cmd" == "state" ]]; then
  cat "${MOCK_STATE_FILE:?}"
  exit 0
fi
if [[ "$cmd" == "apply" ]]; then
  mkdir -p "${MOCK_BUCKET_DIR:?}/$(dirname "${key:?}.lock")"
  printf 'lock-holder\n' > "${MOCK_BUCKET_DIR:?}/${key:?}.lock"
  echo "$$" > "${MOCK_APPLY_PID_FILE:?}"
  sleep "${MOCK_APPLY_HOLD:-3}"
  rm -f "${MOCK_BUCKET_DIR:?}/${key:?}.lock"
  if [[ "${MOCK_APPLY_FAIL:-0}" == "1" ]]; then
    echo "Error: the background apply failed while writing state"
    exit 1
  fi
  echo "Apply complete! Resources: 1 added."
  exit 0
fi
if [[ "$cmd" == "plan" ]]; then
  count="$(<"${MOCK_PLAN_COUNT:?}")"
  count=$((count + 1))
  printf '%s' "$count" > "${MOCK_PLAN_COUNT:?}"
  if [[ "$count" == "1" ]]; then
    if [[ "${MOCK_PLAN_HOLD_RESULT:-fail}" == "success" ]]; then
      echo "No changes. Your infrastructure matches the configuration."
      exit 0
    fi
    if [[ "${MOCK_PLAN_LOCK_ERROR:-1}" == "1" ]]; then
      echo "Error: Error acquiring the state lock. Lock Info: ID: stub-lock-id, Holder: state-lock probe"
    else
      echo "Error: failed to read remote backend state: 500 InternalServerError"
    fi
    exit 1
  fi
  if [[ "${MOCK_PLAN_RELEASE_FAIL:-0}" == "1" ]]; then
    echo "Error: Error acquiring the state lock after destroy."
    exit 1
  fi
  echo "No changes. Your infrastructure matches the configuration."
  exit 0
fi
if [[ "$cmd" == "destroy" ]]; then
  if [[ "${MOCK_DESTROY_FAIL:-0}" == "1" ]]; then
    echo "Error: destroy failed midway"
    exit 1
  fi
  echo "Destroy complete! Resources: 1 destroyed."
  exit 0
fi
echo "stub terraform: unexpected invocation: $*" >&2
exit 64
STUB

cat > "$stub_dir/oci" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "oci $*" >> "${MOCK_OCI_LOG:?}"
# The real OCI CLI accepts global --auth/--profile before or after the service
# path; normalize them away wherever they appear.
args=()
while (( $# )); do
  case "$1" in
    --auth|--profile) shift 2;;
    *) args+=("$1"); shift;;
  esac
done
set -- "${args[@]}"
if [[ "${1:-} ${2:-}" != "os object" ]]; then
  echo "stub oci: unexpected service: $*" >&2
  exit 64
fi
verb="$3"
shift 3
name="" src_vid="" dest_name="" vid_arg="" file_target=""
while (( $# )); do
  case "$1" in
    --name) name="$2"; shift 2;;
    --version-id) vid_arg="$2"; shift 2;;
    --source-object-name) shift 2;;
    --source-version-id) src_vid="$2"; shift 2;;
    --destination-object-name) dest_name="$2"; shift 2;;
    --file) file_target="$2"; shift 2;;
    --bucket-name|--prefix|--source-bucket|--destination-bucket|--source-namespace|--destination-namespace|--destination-region|--wait-interval-seconds|--wait-for-state|--profile|--auth) shift 2;;
    *) shift;;
  esac
done
bucket_dir="${MOCK_BUCKET_DIR:?}"
if [[ "$verb" == "head" ]]; then
  if [[ -f "$bucket_dir/$name" ]]; then
    vid=""
    if [[ -f "$bucket_dir/$name.version" ]]; then
      vid="$(cat "$bucket_dir/$name.version")"
    fi
    printf '{"version-id":"%s","kms-key-id":"ocid1.key.oc1..stub","content-type":"application/json"}\n' "$vid"
    exit 0
  fi
  echo "Object not found" >&2
  exit 1
fi
if [[ "$verb" == "list-object-versions" ]]; then
  if [[ -n "${MOCK_VERSIONS_JSON:-}" && -f "$MOCK_VERSIONS_JSON" ]]; then
    cat "$MOCK_VERSIONS_JSON"
  else
    printf '{"data":[],"prefixes":[]}\n'
  fi
  exit 0
fi
if [[ "$verb" == "copy" ]]; then
  if [[ "${MOCK_COPY_FAIL:-0}" == "1" ]]; then
    echo "WorkRequest state: FAILED" >&2
    exit 1
  fi
  if [[ "${MOCK_COPY_INCOMPLETE:-0}" != "1" ]]; then
    dest="$bucket_dir/$dest_name"
    mkdir -p "$(dirname "$dest")"
    if [[ -n "${MOCK_COPY_CONTENT:-}" && -f "$MOCK_COPY_CONTENT" ]]; then
      cp "$MOCK_COPY_CONTENT" "$dest"
    elif [[ -n "$src_vid" && -f "${MOCK_VERSIONS_DIR:?}/$src_vid" ]]; then
      cp "${MOCK_VERSIONS_DIR:?}/$src_vid" "$dest"
    else
      printf 'copied object' > "$dest"
    fi
    printf 'copied-1' > "$dest.version"
  fi
  echo '{"opc-work-request-id":"stub-work-request"}'
  exit 0
fi
if [[ "$verb" == "get" ]]; then
  src="$bucket_dir/$name"
  if [[ -n "$vid_arg" ]]; then
    src="${MOCK_VERSIONS_DIR:?}/$vid_arg"
  fi
  if [[ ! -f "$src" ]]; then
    echo "Object not found" >&2
    exit 1
  fi
  cp "$src" "$file_target"
  exit 0
fi
echo "stub oci: unexpected object verb: $verb" >&2
exit 64
STUB
chmod +x "$stub_dir/terraform" "$stub_dir/oci"

# ------------------------------------------------------------- harness -------
cdir=""
base_vars=()

setup_case() {
  cdir="$tmp/cases/$1"
  rm -rf "$cdir"
  mkdir -p "$cdir/bucket" "$cdir/evidence" "$cdir/captured" "$cdir/version-content"
  : > "$cdir/tf-calls.log"
  : > "$cdir/oci-calls.log"
  printf '0' > "$cdir/plan-count"
  base_vars=(
    "RUN_ID=$run_id"
    "TF_STATE_BUCKET=$approved_bucket"
    "OCI_OBJECT_STORAGE_NAMESPACE=axrq1dasyz3y"
    "OCI_REGION=ap-hyderabad-1"
    "TERRAFORM_BIN=$stub_dir/terraform"
    "TF_OCI_AUTH=APIKey"
    "TF_OCI_PROFILE=operator"
    "TF_VALIDATION_EVIDENCE_DIR=$cdir/evidence"
    "MOCK_BUCKET_DIR=$cdir/bucket"
    "MOCK_TF_LOG=$cdir/tf-calls.log"
    "MOCK_OCI_LOG=$cdir/oci-calls.log"
    "MOCK_TF_CAPTURE_DIR=$cdir/captured"
    "MOCK_PLAN_COUNT=$cdir/plan-count"
    "MOCK_STATE_FILE=$cdir/state.json"
    "MOCK_VERSIONS_JSON=$cdir/versions.json"
    "MOCK_VERSIONS_DIR=$cdir/version-content"
    "MOCK_APPLY_PID_FILE=$cdir/apply.pid"
  )
}

# Runs the given script in a hermetic environment: only PATH plus the base and
# case-specific variables are inherited, so nothing from the operator shell
# (profiles, OCI_* settings) can leak into a case.
run_case() {
  local tag="$1" script="$2" rc=0
  shift 2
  ( exec env -i PATH="$stub_dir:/usr/bin:/bin" HOME="$tmp" TMPDIR="$tmp" \
      "${base_vars[@]}" "$@" bash "$script" ) \
    > "$cdir/$tag.out" 2> "$cdir/$tag.err" || rc=$?
  printf '%s' "$rc" > "$cdir/$tag.rc"
}

case_rc() { cat "$cdir/$1.rc"; }

expect_ok() {
  local tag="$1"
  if [[ "$(case_rc "$tag")" != "0" ]]; then
    echo "expected $tag to succeed (rc=$(case_rc "$tag"))" >&2
    sed -n '1,40p' "$cdir/$tag.err" >&2
    exit 1
  fi
}

expect_fail() {
  local tag="$1"
  if [[ "$(case_rc "$tag")" == "0" ]]; then
    echo "expected $tag to fail, but it succeeded" >&2
    exit 1
  fi
}

expect_evidence() {
  local marker="${1:-main.tf}"
  if [[ ! -d "$cdir/evidence" ]] || [[ -z "$(find "$cdir/evidence" -name "$marker" -print -quit)" ]]; then
    echo "expected preserved evidence with the temporary root under $cdir/evidence" >&2
    find "$cdir/evidence" 2>/dev/null >&2 || true
    exit 1
  fi
}

die() { echo "FAIL: $*" >&2; exit 1; }

seed_obj() {
  mkdir -p "$(dirname "$cdir/bucket/$1")"
  : > "$cdir/bucket/$1"
}

make_state() {
  jq -nc --arg lineage "$1" --argjson serial "$2" \
    '{version:4,terraform_version:"1.12.2",serial:$serial,lineage:$lineage,outputs:{},resources:[{mode:"managed",type:"terraform_data",name:"lock_probe",instances:[{schema_version:0,attributes:{id:"stub"}}]}]}'
}

make_versions_fixture() {
  jq -nc --arg key "$state_key" '{
    data: [
      {name:$key, size:100, etag:"e-cur", "time-created":"2026-10-27T10:05:00Z", "time-modified":"2026-10-27T10:05:00Z", "version-id":"v-cur", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null},
      {name:$key, size:90, etag:"e-old", "time-created":"2026-10-27T10:03:00Z", "time-modified":"2026-10-27T10:03:00Z", "version-id":"v-old", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null},
      {name:$key, size:80, etag:"e-oldest", "time-created":"2026-10-27T10:01:00Z", "time-modified":"2026-10-27T10:01:00Z", "version-id":"v-oldest", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null},
      {name:$key, size:0, etag:"", "time-created":"2026-10-27T10:02:00Z", "time-modified":"2026-10-27T10:02:00Z", "version-id":"v-marker", "is-delete-marker":true, "storage-tier":"Standard", "archival-state":null}
    ],
    prefixes: []
  }'
}

seed_recovery_fixtures() {
  make_state lin-recovery 11 > "$cdir/version-content/v-oldest"
  make_state lin-recovery 12 > "$cdir/version-content/v-old"
  make_state lin-recovery 13 > "$cdir/version-content/v-cur"
  make_versions_fixture > "$cdir/versions.json"
  seed_obj "$state_key"
  printf 'v-cur' > "$cdir/bucket/$state_key.version"
}

# ===================================================================== verify
# Happy path (APIKey): full lock/contention/release cycle on the derived key.
setup_case verify-happy
make_state lin-verify 7 > "$cdir/state.json"
run_case main "$verify_script"
expect_ok main
grep -q "Observed lock object while held: $lock_key" "$cdir/main.out" || die "lock object name not reported"
grep -q "Validation state key retained for operator review: $state_key" "$cdir/main.out" || die "retained key not reported"
grep -q 'auth                = "APIKey"' "$cdir/captured/backend.hcl" || die "backend must select APIKey auth"
grep -q 'config_file_profile = "operator"' "$cdir/captured/backend.hcl" || die "backend must select the explicit profile"
grep -q "key       = \"$state_key\"" "$cdir/captured/backend.hcl" || die "backend must use the RUN_ID-derived key"
grep -q -- "--auth api_key --profile operator" "$cdir/oci-calls.log" || die "oci calls must carry the selected auth"
first_oci="$(sed -n '1p' "$cdir/oci-calls.log")"
second_oci="$(sed -n '2p' "$cdir/oci-calls.log")"
grep -q -- "--name $state_key" <<<"$first_oci" || die "first remote call must verify the state key is absent"
grep -q -- "--name $lock_key" <<<"$second_oci" || die "second remote call must verify the lock key is absent"
if grep -qE "os object (delete|copy|put|bulk-delete)" "$cdir/oci-calls.log"; then
  die "validation script must never issue object deletes/copies/puts itself"
fi
if [[ -n "$(find "$cdir/evidence" -mindepth 1 -print -quit)" ]]; then
  die "successful run must not preserve evidence"
fi

# An explicitly supplied TF_BACKEND_VALIDATION_KEY is accepted only when it
# matches the RUN_ID-derived key exactly.
setup_case verify-explicit-matching-key
make_state lin-verify 7 > "$cdir/state.json"
run_case main "$verify_script" TF_BACKEND_VALIDATION_KEY="$state_key"
expect_ok main

# Happy path (ResourcePrincipal, the post-federation CI identity).
setup_case verify-happy-rp
make_state lin-rp 3 > "$cdir/state.json"
run_case main "$verify_script" TF_OCI_AUTH=ResourcePrincipal OCI_RESOURCE_PRINCIPAL_VERSION=2.2
expect_ok main
grep -q 'auth                = "ResourcePrincipal"' "$cdir/captured/backend.hcl" || die "RP mode must select ResourcePrincipal auth"
if grep -q 'config_file_profile' "$cdir/captured/backend.hcl"; then
  die "RP mode must not set config_file_profile"
fi
grep -q -- "--auth resource_principal" "$cdir/oci-calls.log" || die "oci calls must use resource-principal auth"

# Explicit RUN_ID enforcement and confinement.
setup_case guard-run-id-missing
run_case main "$verify_script" RUN_ID=
expect_fail main
setup_case guard-run-id-traversal
run_case main "$verify_script" RUN_ID=../../evil
expect_fail main
setup_case guard-run-id-slash
run_case main "$verify_script" RUN_ID=a/b
expect_fail main

# Approved-coordinate fail-closed checks.
for coord in "TF_STATE_BUCKET=other-bucket" \
             "OCI_OBJECT_STORAGE_NAMESPACE=other-ns" \
             "OCI_REGION=us-phoenix-1" \
             "TF_WORKSPACE=staging"; do
  name="guard-coord-$(printf '%s' "$coord" | cut -d= -f1)"
  setup_case "$name"
  run_case main "$verify_script" "$coord"
  expect_fail main
done

# Unauthorized state-key prefixes and key/workspace deviations.
setup_case guard-foreign-key
run_case main "$verify_script" TF_BACKEND_VALIDATION_KEY=platform/terraform.tfstate
expect_fail main
grep -qi "approved live-acceptance prefix" "$cdir/main.err" || die "foreign-key refusal must name the confinement rule"
setup_case guard-bootstrap-key
run_case main "$verify_script" TF_BACKEND_VALIDATION_KEY=bootstrap/terraform.tfstate
expect_fail main
setup_case guard-key-mismatch
run_case main "$verify_script" TF_BACKEND_VALIDATION_KEY="validation/live-acceptance-$run_id/other.tfstate"
expect_fail main

# Reused validation key or surviving lock key refuse before any mutation.
setup_case guard-reused-key
seed_obj "$state_key"
run_case main "$verify_script"
expect_fail main
grep -qi "already exists" "$cdir/main.err" || die "reused-key refusal expected"
setup_case guard-lock-present
seed_obj "$lock_key"
run_case main "$verify_script"
expect_fail main
grep -qi "already exists" "$cdir/main.err" || die "surviving-lock refusal expected"

# Terraform binary pinning.
setup_case guard-tf-version
run_case main "$verify_script" MOCK_TF_VERSION=1.17.0
expect_fail main
grep -qi "unexpected binary or version" "$cdir/main.err" || die "version-pin refusal expected"
setup_case guard-tf-missing
run_case main "$verify_script" TERRAFORM_BIN=
expect_fail main
setup_case guard-tf-nonexistent
run_case main "$verify_script" TERRAFORM_BIN=/nonexistent/terraform
expect_fail main

# Authentication selection.
setup_case guard-auth-missing
run_case main "$verify_script" TF_OCI_AUTH=
expect_fail main
setup_case guard-auth-unknown
run_case main "$verify_script" TF_OCI_AUTH=InstancePrincipal
expect_fail main
setup_case guard-auth-profile-missing
run_case main "$verify_script" TF_OCI_PROFILE=
expect_fail main
setup_case guard-auth-profile-conflict
run_case main "$verify_script" OCI_CLI_PROFILE=someone-else
expect_fail main
setup_case guard-auth-rp-missing-env
run_case main "$verify_script" TF_OCI_AUTH=ResourcePrincipal
expect_fail main
setup_case guard-nondefault-workspace
run_case main "$verify_script" MOCK_TF_WORKSPACE=staging
expect_fail main
expect_evidence

# Background Terraform failure preserves evidence.
setup_case fail-background-apply
run_case main "$verify_script" MOCK_APPLY_FAIL=1
expect_fail main
expect_evidence
grep -qi "failed before lock contention" "$cdir/main.err" || grep -qi "failed after the contention check" "$cdir/main.err" || die "background apply failure must be reported"

# Lock contention must fail the concurrent plan, and only for lock reasons.
setup_case fail-plan-succeeded
run_case main "$verify_script" MOCK_PLAN_HOLD_RESULT=success
expect_fail main
expect_evidence
grep -qi "expected concurrent terraform plan to fail" "$cdir/main.err" || die "unexpected plan success must be reported"
setup_case fail-plan-not-lock
run_case main "$verify_script" MOCK_PLAN_LOCK_ERROR=0
expect_fail main
expect_evidence
grep -qi "other than state locking" "$cdir/main.err" || die "non-lock plan failure must be reported"

# Destroy failure and post-destroy lock failure preserve evidence and demand a
# separately approved lock deletion.
setup_case fail-destroy
make_state lin-destroy 9 > "$cdir/state.json"
run_case main "$verify_script" MOCK_DESTROY_FAIL=1
expect_fail main
expect_evidence
grep -qi "separate scoped approval" "$cdir/main.err" || die "destroy failure must point at the scoped lock-deletion approval"
setup_case fail-post-destroy-lock
make_state lin-release 9 > "$cdir/state.json"
run_case main "$verify_script" MOCK_PLAN_RELEASE_FAIL=1
expect_fail main
expect_evidence
grep -qi "separate scoped approval" "$cdir/main.err" || die "post-destroy lock failure must point at the scoped approval"

# Interrupted execution (TERM and INT) reaps the background apply and keeps
# the evidence.
for sig in TERM INT; do
  setup_case "interrupt-$sig"
  # set -m gives the backgrounded script its own job-control context; without
  # it an async command inherits SIGINT=ignore and "signals ignored on entry
  # cannot be trapped", so the INT case would silently never fire.
  set -m
  ( exec env -i PATH="$stub_dir:/usr/bin:/bin" HOME="$tmp" TMPDIR="$tmp" \
      "${base_vars[@]}" MOCK_APPLY_HOLD=30 bash "$verify_script" ) \
    > "$cdir/main.out" 2> "$cdir/main.err" &
  script_pid=$!
  tries=0
  while (( tries < 100 )) && [[ ! -s "$cdir/apply.pid" ]]; do
    sleep 0.2
    tries=$((tries + 1))
  done
  if [[ ! -s "$cdir/apply.pid" ]]; then
    die "stub apply never started"
  fi
  apply_pid="$(cat "$cdir/apply.pid")"
  kill -"$sig" "$script_pid"
  wait_rc=0
  wait "$script_pid" || wait_rc=$?
  set +m
  grep -qi "interrupted by a signal" "$cdir/main.err" || die "interrupt must be reported"
  if [[ "$wait_rc" == "0" ]]; then
    die "interrupted validation must exit non-zero (got 0)"
  fi
  expect_evidence
  tries=0
  while kill -0 "$apply_pid" 2>/dev/null; do
    sleep 0.5
    tries=$((tries + 1))
    if (( tries > 30 )); then
      die "background apply survived the interrupted validation script"
    fi
  done
done

# ==================================================================== denied
setup_case denied-happy
run_case main "$denied_script" TF_OCI_PROFILE=denied-probe MOCK_INIT_FAIL=1
expect_ok main
grep -q 'config_file_profile = "denied-probe"' "$cdir/captured/backend.hcl" || die "denied probe must select its explicit profile"
grep -q -- "--profile denied-probe" "$cdir/oci-calls.log" || die "denied probe oci calls must use the underprivileged profile"

setup_case denied-default-profile
run_case main "$denied_script" TF_OCI_PROFILE=DEFAULT MOCK_INIT_FAIL=1
expect_fail main
grep -qi "must not run under the privileged DEFAULT profile" "$cdir/main.err" || die "DEFAULT profile must be refused"

setup_case denied-profile-missing
run_case main "$denied_script" TF_OCI_PROFILE=
expect_fail main

setup_case denied-auth-missing
run_case main "$denied_script" TF_OCI_AUTH=
expect_fail main

setup_case denied-wrong-bucket
run_case main "$denied_script" TF_STATE_BUCKET=other-bucket
expect_fail main

setup_case denied-production-key
run_case main "$denied_script" TF_BACKEND_VALIDATION_KEY=bootstrap/terraform.tfstate
expect_fail main

setup_case denied-init-succeeded
run_case main "$denied_script" TF_OCI_PROFILE=denied-probe
expect_fail main
grep -qi "expected the underprivileged identity to be denied" "$cdir/main.err" || die "unexpected init success must be reported"

setup_case denied-not-authorization
run_case main "$denied_script" TF_OCI_PROFILE=denied-probe MOCK_INIT_FAIL=1 MOCK_INIT_FAIL_MSG="Error: network timeout"
expect_fail main
grep -qi "other than an authorization denial" "$cdir/main.err" || die "non-denial failure must be reported"
expect_evidence

setup_case denied-unexpected-write
run_case main "$denied_script" TF_OCI_PROFILE=denied-probe MOCK_INIT_FAIL=1 MOCK_INIT_WRITES=1
expect_fail main
grep -qi "presence changed" "$cdir/main.err" || die "an object appearing despite denial must stop the probe"

setup_case denied-rp-mode
run_case main "$denied_script" TF_OCI_AUTH=ResourcePrincipal OCI_RESOURCE_PRINCIPAL_VERSION=2.2 MOCK_INIT_FAIL=1
expect_ok main
grep -q 'auth                = "ResourcePrincipal"' "$cdir/captured/backend.hcl" || die "RP denial probe must select ResourcePrincipal"

# ================================================================= recovery
setup_case recovery-happy
seed_recovery_fixtures
make_state lin-recovery 11 > "$cdir/state.json"
run_case main "$recovery_script"
expect_ok main
grep -q "os object list-object-versions" "$cdir/oci-calls.log" || die "recovery must use the supported list-object-versions command"
if grep -qE "os object list-versions " "$cdir/oci-calls.log"; then
  die "recovery must not use the unsupported list-versions command"
fi
copy_line="$(grep "os object copy" "$cdir/oci-calls.log")"
grep -q -- "--source-version-id v-oldest" <<<"$copy_line" || die "oldest noncurrent version must be selected"
grep -q -- "--wait-for-state COMPLETED" <<<"$copy_line" || die "copy must wait for async completion"
grep -q -- "--destination-object-name $restore_key" <<<"$copy_line" || die "copy must target the restore-test prefix"
grep -q -- "--destination-region ap-hyderabad-1" <<<"$copy_line" || die "copy must pin the approved destination region"
grep -q "Restored $state_key version v-oldest to $restore_key" "$cdir/main.out" || die "restored pair must be reported"

setup_case recovery-explicit-version
seed_recovery_fixtures
make_state lin-recovery 12 > "$cdir/state.json"
run_case main "$recovery_script" TF_RESTORE_VERSION_ID=v-old
expect_ok main
copy_line="$(grep "os object copy" "$cdir/oci-calls.log")"
grep -q -- "--source-version-id v-old" <<<"$copy_line" || die "explicit version must be honored"

setup_case recovery-destination-present
seed_recovery_fixtures
seed_obj "$restore_key"
run_case main "$recovery_script"
expect_fail main
grep -qi "already exists" "$cdir/main.err" || die "occupied restore-test key must be refused"

setup_case recovery-no-noncurrent
jq -nc --arg key "$state_key" '{data:[{name:$key, size:1, etag:"e", "time-created":"2026-10-27T10:05:00Z", "time-modified":"2026-10-27T10:05:00Z", "version-id":"v-cur", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null}], prefixes:[]}' > "$cdir/versions.json"
seed_obj "$state_key"
printf 'v-cur' > "$cdir/bucket/$state_key.version"
run_case main "$recovery_script"
expect_fail main
grep -qi "no noncurrent version" "$cdir/main.err" || die "missing noncurrent version must be reported"

setup_case recovery-bad-explicit-version
seed_recovery_fixtures
run_case main "$recovery_script" TF_RESTORE_VERSION_ID=v-cur
expect_fail main
grep -qi "not a noncurrent version" "$cdir/main.err" || die "current version must be refused as TF_RESTORE_VERSION_ID"

setup_case recovery-production-source
run_case main "$recovery_script" TF_RESTORE_SOURCE_KEY=bootstrap/terraform.tfstate
expect_fail main

setup_case recovery-copy-failed
seed_recovery_fixtures
run_case main "$recovery_script" MOCK_COPY_FAIL=1
expect_fail main
expect_evidence copy.log
grep -qi "did not complete successfully" "$cdir/main.err" || die "failed async copy must be reported"

setup_case recovery-copy-incomplete
seed_recovery_fixtures
make_state lin-recovery 11 > "$cdir/state.json"
run_case main "$recovery_script" MOCK_COPY_INCOMPLETE=1
expect_fail main
grep -qi "treating the copy as incomplete" "$cdir/main.err" || die "incomplete async copy must be detected"
expect_evidence copy.log

setup_case recovery-snapshot-mismatch
make_state lin-recovery 11 > "$cdir/version-content/v-oldest"
make_state lin-recovery 12 > "$cdir/version-content/v-old"
make_state lin-recovery 13 > "$cdir/version-content/v-cur"
make_versions_fixture > "$cdir/versions.json"
seed_obj "$state_key"
printf 'v-cur' > "$cdir/bucket/$state_key.version"
make_state other-lineage 99 > "$cdir/wrong.json"
run_case main "$recovery_script" MOCK_COPY_CONTENT="$cdir/wrong.json"
expect_fail main
grep -qi "mismatch" "$cdir/main.err" || die "restored snapshot mismatch must be reported"
expect_evidence copy.log

echo "OCI live-validation guard fixtures passed"
