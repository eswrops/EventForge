#!/usr/bin/env bash
set -euo pipefail

# Offline regression suite for the hardened live OCI validation scripts.
# Every live mutation path is exercised against stub `terraform` and `oci`
# binaries that simulate lock objects, versioned objects, listings with
# pagination, work-request behavior, and KMS metadata, so no network call and
# no real bucket is ever touched.

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
approved_namespace="axrq1dasyz3y"
approved_kms="ocid1.key.oc1.ap-hyderabad-1.stubkms"
approved_compartment="ocid1.tenancy.oc1..stubcompartment"
stub_mgmt_endpoint="https://stub-vault.management.kms.ap-hyderabad-1.oraclecloud.com"
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
  # Record how many oci calls happened before init so tests can assert that
  # the preconditions and absence checks ran first.
  wc -l < "${MOCK_OCI_LOG:?}" > "${MOCK_TF_CAPTURE_DIR:?}/oci-lines-before-init"
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
      # Deliberately mentions "lock" without being a state-lock error: the
      # script's contention assertion must not produce a false PASS on it.
      echo "Error: failed to read remote backend state: 500 InternalServerError while refreshing the backend lock metadata"
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
bucket_dir="${MOCK_BUCKET_DIR:?}"
name="" prefix="" src_vid="" dest_name="" vid_arg="" file_target=""

parse_flags() {
  while (( $# )); do
    case "$1" in
      --name) name="$2"; shift 2;;
      --prefix) prefix="$2"; shift 2;;
      --version-id) vid_arg="$2"; shift 2;;
      --source-object-name) shift 2;;
      --source-version-id) src_vid="$2"; shift 2;;
      --destination-object-name) dest_name="$2"; shift 2;;
      --file) file_target="$2"; shift 2;;
      --all) shift;;
      --bucket-name|--namespace-name|--source-bucket|--destination-bucket|--source-namespace|--destination-namespace|--destination-region|--destination-object-if-none-match-e-tag|--wait-interval-seconds|--wait-for-state|--key-id) shift 2;;
      *) shift;;
    esac
  done
}

if [[ "${1:-}" == "os" && "${2:-}" == "ns" ]]; then
  # oci os ns get — the real CLI returns the wrapped envelope {"data":"<ns>"}.
  if [[ "${MOCK_NS_FAIL:-0}" == "1" ]]; then
    echo "${MOCK_NS_FAIL_MSG:-ServiceError: NotAuthenticatedOrUnauthorized}" >&2
    exit 1
  fi
  if [[ -n "${MOCK_NS_JSON:-}" && -f "$MOCK_NS_JSON" ]]; then
    cat "$MOCK_NS_JSON"
  else
    printf '{"data":"%s"}\n' "${MOCK_NAMESPACE:?}"
  fi
  exit 0
fi
if [[ "${1:-}" == "os" && "${2:-}" == "bucket" ]]; then
  # oci os bucket get
  parse_flags "${@:3}"
  if [[ "${MOCK_BUCKET_FAIL:-0}" == "1" ]]; then
    echo "${MOCK_BUCKET_FAIL_MSG:-ServiceError: NotAuthorizedOrNotFound}" >&2
    exit 1
  fi
  cat "${MOCK_BUCKET_JSON:?}"
  exit 0
fi
if [[ "${1:-}" == "kms" && "${2:-}" == "management" ]]; then
  verb="${3:-}"
  if [[ "$verb" == "vault" ]]; then
    # oci kms management vault list — regional call, no --endpoint involved.
    if [[ "${MOCK_KMS_VAULTS_FAIL:-0}" == "1" ]]; then
      echo "${MOCK_KMS_VAULTS_FAIL_MSG:-ServiceError: NotAuthorizedOrNotFound}" >&2
      exit 1
    fi
    if [[ -n "${MOCK_KMS_VAULTS_JSON:-}" && -f "$MOCK_KMS_VAULTS_JSON" ]]; then
      cat "$MOCK_KMS_VAULTS_JSON"
    else
      printf '{"data":[],"prefixes":[]}\n'
    fi
    exit 0
  fi
  if [[ "$verb" == "key" ]]; then
    # oci kms management key get — the real CLI REQUIRES the vault's
    # management endpoint: without --endpoint it fails before any request.
    endpoint="" key_id=""
    while (( $# )); do
      case "$1" in
        --endpoint) endpoint="$2"; shift 2;;
        --key-id) key_id="$2"; shift 2;;
        *) shift;;
      esac
    done
    if [[ -z "$endpoint" ]]; then
      echo "Error: Missing option --endpoint." >&2
      exit 2
    fi
    # An endpoint other than the stub vault's management endpoint must fail
    # the lookup, exactly as a foreign vault would live.
    if [[ "$endpoint" != "${MOCK_KMS_MANAGEMENT_ENDPOINT:?}" ]]; then
      echo "ServiceError: NotAuthorizedOrNotFound from ${endpoint}" >&2
      exit 1
    fi
    if [[ "${MOCK_KMS_FAIL:-0}" == "1" ]]; then
      echo "${MOCK_KMS_FAIL_MSG:-ServiceError: NotAuthorizedOrNotFound}" >&2
      exit 1
    fi
    cat "${MOCK_KMS_JSON:?}"
    exit 0
  fi
  echo "stub oci: unexpected kms management verb: $verb" >&2
  exit 64
fi
if [[ "${1:-}" != "os" || "${2:-}" != "object" ]]; then
  echo "stub oci: unexpected service: $*" >&2
  exit 64
fi
verb="$3"
shift 3
parse_flags "$@"

if [[ "$verb" == "head" ]]; then
  if [[ -f "$bucket_dir/$name" ]]; then
    vid=""
    if [[ -f "$bucket_dir/$name.version" ]]; then
      vid="$(cat "$bucket_dir/$name.version")"
    fi
    printf '{"version-id":"%s","kms-key-id":"%s","content-type":"application/json"}\n' "$vid" "${MOCK_HEAD_KMS:-ocid1.key.oc1.ap-hyderabad-1.stubkms}"
    exit 0
  fi
  echo "Object not found" >&2
  exit 1
fi
if [[ "$verb" == "list" ]]; then
  if [[ "${MOCK_LIST_FAIL:-0}" == "1" ]]; then
    echo "${MOCK_LIST_FAIL_MSG:-ServiceError: NotAuthorizedOrNotFound}" >&2
    exit 1
  fi
  if [[ -n "${MOCK_LIST_JSON:-}" ]]; then
    cat "$MOCK_LIST_JSON"
    exit 0
  fi
  names=""
  while IFS= read -r f; do
    rel="${f#"$bucket_dir"/}"
    case "$rel" in
      *.version) continue;;
      "$prefix"*) names="${names}${rel}"$'\n';;
    esac
  done < <(find "$bucket_dir" -type f | sort)
  if [[ -n "$names" ]]; then
    printf '%s' "$names" | jq -Rn --arg p "$prefix" '{data:[inputs|select(startswith($p))|{name:.,size:0,etag:"stub"}],prefixes:[]}'
  else
    # The real CLI renders an EMPTY listing with no data key at all.
    printf '{"prefixes":[]}\n'
  fi
  exit 0
fi
if [[ "$verb" == "list-object-versions" ]]; then
  if [[ "${MOCK_VERSIONS_FAIL:-0}" == "1" ]]; then
    echo "${MOCK_VERSIONS_FAIL_MSG:-ServiceError: InternalServerError while paginating versions}" >&2
    exit 1
  fi
  if [[ -n "${MOCK_VERSIONS_JSON:-}" && -f "$MOCK_VERSIONS_JSON" ]]; then
    cat "$MOCK_VERSIONS_JSON"
  else
    # The real CLI renders an EMPTY version listing with no data key at all.
    printf '{"prefixes":[]}\n'
  fi
  exit 0
fi
if [[ "$verb" == "copy" ]]; then
  if [[ "${MOCK_COPY_FAIL:-0}" == "1" ]]; then
    echo "WorkRequest state: FAILED" >&2
    exit 1
  fi
  dest="$bucket_dir/$dest_name"
  mkdir -p "$(dirname "$dest")"
  if [[ "${MOCK_COPY_RACE:-0}" == "1" ]]; then
    printf 'concurrent writer got here first' > "$dest"
  fi
  # The real service rejects a copy carrying --destination-object-if-none-match-e-tag '*'
  # when the destination already exists.
  if [[ "${MOCK_COPY_PRECONDITION:-0}" == "1" || -f "$dest" ]]; then
    echo "WorkRequest state: FAILED; PreconditionFailed: destination object already exists" >&2
    exit 1
  fi
  if [[ "${MOCK_COPY_INCOMPLETE:-0}" != "1" ]]; then
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
  jq -n --arg kms "$approved_kms" \
    '{data:{"public-access-type":"NoPublicAccess","versioning":"Enabled","kms-key-id":$kms}}' \
    > "$cdir/bucket.json"
  # Realistic KMS fixtures: vault list renders the raw collection with each
  # ACTIVE vault's management-endpoint; key get returns the wrapped
  # {"data":{"id":...,"lifecycle-state":...}} envelope.
  jq -n --arg ep "$stub_mgmt_endpoint" --arg comp "$approved_compartment" \
    '{data:[{id:"ocid1.vault.oc1.ap-hyderabad-1.stubvault",
             "compartment-id":$comp,
             "lifecycle-state":"ACTIVE",
             "display-name":"stub-vault",
             "vault-type":"VIRTUAL_PRIVATE",
             "crypto-endpoint":"https://stub-vault.crypto.kms.ap-hyderabad-1.oraclecloud.com",
             "management-endpoint":$ep,
             "time-created":"2026-10-01T00:00:00Z",
             "defined-tags":{},"freeform-tags":{},
             "external-key-manager-metadata-summary":null}]}' \
    > "$cdir/kms-vaults.json"
  jq -n --arg kms "$approved_kms" --arg comp "$approved_compartment" \
    '{data:{id:$kms,"lifecycle-state":"ENABLED",
            "compartment-id":$comp,"curve-id":"NIST_P384",
            "protection-mode":"HSM","algorithm":"AES",
            "time-created":"2026-10-01T00:00:00Z"}}' \
    > "$cdir/kms.json"
  base_vars=(
    "RUN_ID=$run_id"
    "TF_STATE_BUCKET=$approved_bucket"
    "OCI_OBJECT_STORAGE_NAMESPACE=$approved_namespace"
    "OCI_REGION=ap-hyderabad-1"
    "TF_VALIDATION_EXPECTED_KMS_KEY_ID=$approved_kms"
    "TF_VALIDATION_KMS_COMPARTMENT_OCID=$approved_compartment"
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
    "MOCK_NAMESPACE=$approved_namespace"
    "MOCK_BUCKET_JSON=$cdir/bucket.json"
    "MOCK_KMS_JSON=$cdir/kms.json"
    "MOCK_KMS_VAULTS_JSON=$cdir/kms-vaults.json"
    "MOCK_KMS_MANAGEMENT_ENDPOINT=$stub_mgmt_endpoint"
  )
}

set_bucket_field() {
  jq --arg k "$1" --arg v "$2" '.data[$k]=$v' "$cdir/bucket.json" > "$cdir/bucket.json.new" \
    && mv "$cdir/bucket.json.new" "$cdir/bucket.json"
}

set_kms_state() {
  jq --arg s "$1" '."data"."lifecycle-state"=$s' "$cdir/kms.json" > "$cdir/kms.json.new" \
    && mv "$cdir/kms.json.new" "$cdir/kms.json"
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

make_state() {
  jq -nc --arg lineage "$1" --argjson serial "$2" \
    '{version:4,terraform_version:"1.12.2",serial:$serial,lineage:$lineage,outputs:{},resources:[{mode:"managed",type:"terraform_data",name:"lock_probe",instances:[{schema_version:0,attributes:{id:"stub"}}]}]}'
}

# Version fixtures come in BOTH real envelopes: "items" (default) is the raw
# collection {"data":{"items":[...],"prefixes":[...]}} that the generated CLI
# path renders, and "flat" is the extended CLI renderer's flattened
# {"data":[...],"prefixes":[...]} — verified live on OCI CLI 3.95.1. The
# validation scripts must accept exactly these and nothing else.
make_versions_fixture() {
  local envelope="${1:-items}"
  jq -nc --arg key "$state_key" --arg env "$envelope" '
    ([
      {name:$key, size:100, etag:"e-cur", "time-created":"2026-10-27T10:05:00Z", "time-modified":"2026-10-27T10:05:00Z", "version-id":"v-cur", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null},
      {name:$key, size:90, etag:"e-old", "time-created":"2026-10-27T10:03:00Z", "time-modified":"2026-10-27T10:03:00Z", "version-id":"v-old", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null},
      {name:$key, size:80, etag:"e-oldest", "time-created":"2026-10-27T10:01:00Z", "time-modified":"2026-10-27T10:01:00Z", "version-id":"v-oldest", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null},
      {name:$key, size:0, etag:"", "time-created":"2026-10-27T10:02:00Z", "time-modified":"2026-10-27T10:02:00Z", "version-id":"v-marker", "is-delete-marker":true, "storage-tier":"Standard", "archival-state":null}
    ]) as $items
    | (if $env == "flat" then {data:$items, prefixes:[]}
       else {data:{items:$items, prefixes:[]}} end)'
}

# Version fixtures for the ABSENCE checks: a reused key whose current object
# is gone but whose history remains.
make_prev_versions_only_fixture() {
  local envelope="${1:-items}"
  jq -nc --arg key "$state_key" --arg env "$envelope" '
    ([{name:$key, size:80, etag:"e-old", "time-created":"2026-10-27T10:01:00Z", "time-modified":"2026-10-27T10:01:00Z", "version-id":"v-old", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null}]) as $items
    | (if $env == "flat" then {data:$items, prefixes:[]}
       else {data:{items:$items, prefixes:[]}} end)'
}

make_delete_marker_only_fixture() {
  local envelope="${1:-items}"
  jq -nc --arg key "$state_key" --arg env "$envelope" '
    ([{name:$key, size:0, etag:"", "time-created":"2026-10-27T10:02:00Z", "time-modified":"2026-10-27T10:02:00Z", "version-id":"v-marker", "is-delete-marker":true, "storage-tier":"Standard", "archival-state":null}]) as $items
    | (if $env == "flat" then {data:$items, prefixes:[]}
       else {data:{items:$items, prefixes:[]}} end)'
}

# Versions of a PREFIX-NEIGHBORING name only: exact-name matching must treat
# this as absence of the exact key.
make_neighbor_versions_fixture() {
  local envelope="${1:-items}"
  jq -nc --arg key "${state_key}.neighbor" --arg env "$envelope" '
    ([{name:$key, size:80, etag:"e-nb", "time-created":"2026-10-27T10:01:00Z", "time-modified":"2026-10-27T10:01:00Z", "version-id":"v-nb", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null}]) as $items
    | (if $env == "flat" then {data:$items, prefixes:[]}
       else {data:{items:$items, prefixes:[]}} end)'
}

seed_recovery_fixtures() {
  make_state lin-recovery 11 > "$cdir/version-content/v-oldest"
  make_state lin-recovery 12 > "$cdir/version-content/v-old"
  make_state lin-recovery 13 > "$cdir/version-content/v-cur"
  make_versions_fixture "${1:-items}" > "$cdir/versions.json"
  mkdir -p "$cdir/bucket/$(dirname "$state_key")"
  : > "$cdir/bucket/$state_key"
  printf 'v-cur' > "$cdir/bucket/$state_key.version"
}

# ===================================================================== verify
# Happy path (APIKey): preconditions, absence proofs, then the full
# lock/contention/release cycle on the derived key. The version listing comes
# from the RAW {"data":{"items":[...]}} envelope carrying only a
# prefix-neighboring name, so the happy path proves both the envelope
# acceptance and exact-name matching.
setup_case verify-happy
make_state lin-verify 7 > "$cdir/state.json"
make_neighbor_versions_fixture > "$cdir/versions.json"
run_case main "$verify_script"
expect_ok main
grep -q "Observed lock object while held: $lock_key" "$cdir/main.out" || die "lock object name not reported"
grep -q "Validation state key retained for operator review: $state_key" "$cdir/main.out" || die "retained key not reported"
grep -q 'auth                = "APIKey"' "$cdir/captured/backend.hcl" || die "backend must select APIKey auth"
grep -q 'config_file_profile = "operator"' "$cdir/captured/backend.hcl" || die "backend must select the explicit profile"
grep -q "key       = \"$state_key\"" "$cdir/captured/backend.hcl" || die "backend must use the RUN_ID-derived key"
grep -q -- "--auth api_key --profile operator" "$cdir/oci-calls.log" || die "oci calls must carry the selected auth"
# Preconditions ran, and every absence proof used successful, fully paginated
# listings of both keys before anything was written.
grep -q "os ns get" "$cdir/oci-calls.log" || die "authenticated namespace must be verified"
grep -q "os bucket get" "$cdir/oci-calls.log" || die "bucket encryption preconditions must be verified"
grep -q "kms management vault list" "$cdir/oci-calls.log" || die "the vault management endpoint must be discovered via vault list"
grep -q "kms management key get" "$cdir/oci-calls.log" || die "CMK liveness must be verified"
grep -qF -- "kms management key get --key-id $approved_kms --endpoint $stub_mgmt_endpoint" "$cdir/oci-calls.log" \
  || die "CMK lookup must target the vault's actual management endpoint"
for k in "$state_key" "$lock_key"; do
  grep -qF "os object list --bucket-name $approved_bucket --prefix $k --all" "$cdir/oci-calls.log" \
    || die "exact-key object listing with --all required for $k"
  grep -qF "os object list-object-versions --bucket-name $approved_bucket --prefix $k --all" "$cdir/oci-calls.log" \
    || die "exact-key version listing with --all required for $k"
done
before_init="$(cat "$cdir/captured/oci-lines-before-init")"
if (( before_init < 8 )); then
  die "preconditions and absence listings must complete before terraform init (got $before_init calls)"
fi
if grep -qE "os object (delete|put|bulk-delete)" "$cdir/oci-calls.log"; then
  die "validation script must never issue object deletes/puts itself"
fi
if [[ -n "$(find "$cdir/evidence" -mindepth 1 -print -quit)" ]]; then
  die "successful run must not preserve evidence"
fi

# The same happy path against the EXTENDED renderer's flattened envelope.
setup_case verify-happy-flat-envelope
make_state lin-verify 7 > "$cdir/state.json"
make_neighbor_versions_fixture flat > "$cdir/versions.json"
run_case main "$verify_script"
expect_ok main

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

# Bucket encryption/visibility preconditions (read-only, before mutation).
setup_case guard-bucket-public
set_bucket_field "public-access-type" "ObjectReadWithoutList"
run_case main "$verify_script"
expect_fail main
grep -qi "does not satisfy the approved preconditions" "$cdir/main.err" || die "public bucket must be refused"
setup_case guard-bucket-unversioned
set_bucket_field "versioning" ""
run_case main "$verify_script"
expect_fail main
setup_case guard-bucket-wrong-cmk
set_bucket_field "kms-key-id" "ocid1.key.oc1.ap-hyderabad-1.notthekey"
run_case main "$verify_script"
expect_fail main
setup_case guard-bucket-get-failed
run_case main "$verify_script" MOCK_BUCKET_FAIL=1 MOCK_BUCKET_FAIL_MSG="ServiceError: NotAuthorizedOrNotFound"
expect_fail main
grep -qi "aborting without any mutation" "$cdir/main.err" || die "failed bucket read must abort without mutation"
setup_case guard-kms-disabled
set_kms_state "DISABLED"
run_case main "$verify_script"
expect_fail main
grep -qi "not ENABLED" "$cdir/main.err" || die "disabled CMK must abort"
setup_case guard-kms-env-missing
run_case main "$verify_script" TF_VALIDATION_EXPECTED_KMS_KEY_ID=
expect_fail main
grep -qi "TF_VALIDATION_EXPECTED_KMS_KEY_ID is required" "$cdir/main.err" || die "missing expected-CMK constant must abort"
setup_case guard-ns-mismatch
run_case main "$verify_script" MOCK_NAMESPACE=other-namespace
expect_fail main
grep -qi "is not the approved" "$cdir/main.err" || die "namespace mismatch must abort"
setup_case guard-ns-malformed-envelope
printf '%s' '{"nope":true}' > "$cdir/ns.json"
run_case main "$verify_script" MOCK_NS_JSON="$cdir/ns.json"
expect_fail main
grep -qi 'expected {"data":"<namespace>"}' "$cdir/main.err" || die "malformed namespace envelope must abort"
setup_case guard-ns-wrong-type
printf '%s' '{"data":123}' > "$cdir/ns.json"
run_case main "$verify_script" MOCK_NS_JSON="$cdir/ns.json"
expect_fail main
grep -qi "Could not parse the authenticated" "$cdir/main.err" || die "non-string namespace must be refused"
setup_case guard-ns-empty-string
printf '%s' '{"data":""}' > "$cdir/ns.json"
run_case main "$verify_script" MOCK_NS_JSON="$cdir/ns.json"
expect_fail main
setup_case guard-ns-failed
run_case main "$verify_script" MOCK_NS_FAIL=1
expect_fail main
grep -qi "aborting without any mutation" "$cdir/main.err" || die "failed namespace read must abort without mutation"
setup_case guard-bucket-malformed
printf '%s' '{"data":{"oops":true}}' > "$cdir/bucket.json"
run_case main "$verify_script"
expect_fail main
grep -qi "malformed" "$cdir/main.err" || die "malformed bucket response must abort"

# KMS contract: the CMK must be found ENABLED through the vault's ACTUAL
# management endpoint, reading the wrapped .data envelope.
setup_case guard-kms-unwrapped-envelope
jq -n --arg kms "$approved_kms" '{id:$kms,"lifecycle-state":"ENABLED"}' > "$cdir/kms.json"
run_case main "$verify_script"
expect_fail main
grep -qi "Malformed KMS key response" "$cdir/main.err" || die "unwrapped key envelope must be refused"
setup_case guard-kms-wrong-key-id
jq '.data.id="ocid1.key.oc1.ap-hyderabad-1.someotherkey"' "$cdir/kms.json" > "$cdir/kms.json.new" \
  && mv "$cdir/kms.json.new" "$cdir/kms.json"
run_case main "$verify_script"
expect_fail main
grep -qi "returned key id" "$cdir/main.err" || die "foreign key id from the vault must abort"
setup_case guard-kms-comp-missing
run_case main "$verify_script" TF_VALIDATION_KMS_COMPARTMENT_OCID=
expect_fail main
grep -qi "TF_VALIDATION_KMS_COMPARTMENT_OCID is required" "$cdir/main.err" || die "missing KMS compartment must abort"
setup_case guard-kms-comp-malformed
run_case main "$verify_script" TF_VALIDATION_KMS_COMPARTMENT_OCID=notanocid
expect_fail main
grep -qi "not a tenancy or compartment OCID" "$cdir/main.err" || die "malformed compartment OCID must abort"
setup_case guard-kms-vault-list-failed
run_case main "$verify_script" MOCK_KMS_VAULTS_FAIL=1
expect_fail main
grep -qi "Could not list KMS vaults" "$cdir/main.err" || die "failed vault listing must abort"
setup_case guard-kms-vaults-malformed
printf '%s' '{"data":"not-a-collection"}' > "$cdir/kms-vaults.json"
run_case main "$verify_script"
expect_fail main
grep -qi "Malformed KMS vault-list response" "$cdir/main.err" || die "malformed vault listing must abort"
setup_case guard-kms-no-active-vault
printf '%s' '{"data":[{"id":"ocid1.vault.oc1.ap-hyderabad-1.stubvault","lifecycle-state":"DELETED","management-endpoint":"'"$stub_mgmt_endpoint"'"}],"prefixes":[]}' > "$cdir/kms-vaults.json"
run_case main "$verify_script"
expect_fail main
grep -qi "not found ENABLED via any ACTIVE vault" "$cdir/main.err" || die "no ACTIVE vault must abort"
setup_case guard-kms-wrong-endpoint
jq -n --arg ep "https://foreign-vault.management.kms.ap-hyderabad-1.oraclecloud.com" \
  '.data[0]."management-endpoint"=$ep' "$cdir/kms-vaults.json" > "$cdir/kms-vaults.json.new" \
  && mv "$cdir/kms-vaults.json.new" "$cdir/kms-vaults.json"
run_case main "$verify_script"
expect_fail main
grep -qi "not found ENABLED via any ACTIVE vault" "$cdir/main.err" || die "an incorrect management endpoint must never verify the CMK"
setup_case guard-kms-key-missing
run_case main "$verify_script" MOCK_KMS_FAIL=1
expect_fail main
grep -qi "not found ENABLED via any ACTIVE vault" "$cdir/main.err" || die "an unreachable CMK must abort"

# Absence checks: a failed or unverifiable listing is never absence.
setup_case absence-list-403
run_case main "$verify_script" MOCK_LIST_FAIL=1 MOCK_LIST_FAIL_MSG="ServiceError: NotAuthorizedOrNotFound (403)"
expect_fail main
grep -qi "never treated as absence" "$cdir/main.err" || die "403 listing must not be treated as absence"
setup_case absence-list-500
run_case main "$verify_script" MOCK_LIST_FAIL=1 MOCK_LIST_FAIL_MSG="ServiceError: InternalServerError (500)"
expect_fail main
grep -qi "never treated as absence" "$cdir/main.err" || die "500 listing must not be treated as absence"
setup_case absence-versions-failed
run_case main "$verify_script" MOCK_VERSIONS_FAIL=1 MOCK_VERSIONS_FAIL_MSG="ServiceError: InternalServerError while paginating versions"
expect_fail main
grep -qi "never treated as absence" "$cdir/main.err" || die "failed version listing must abort"
setup_case absence-list-malformed
printf '%s' '{"nope":true}' > "$cdir/list.json"
run_case main "$verify_script" MOCK_LIST_JSON="$cdir/list.json"
expect_fail main
grep -qi "malformed object-listing response" "$cdir/main.err" || die "malformed listing must abort"
setup_case absence-versions-malformed
printf '%s' '{"oops":1}' > "$cdir/versions.json"
run_case main "$verify_script"
expect_fail main
grep -qi "malformed" "$cdir/main.err" || die "malformed version response must abort"
setup_case absence-versions-items-malformed
printf '%s' '{"data":{"items":"not-an-array"}}' > "$cdir/versions.json"
run_case main "$verify_script"
expect_fail main
grep -qi "malformed object-version response" "$cdir/main.err" || die "non-array version items must abort"
setup_case absence-versions-scalar-data
printf '%s' '{"data":123}' > "$cdir/versions.json"
run_case main "$verify_script"
expect_fail main
grep -qi "malformed object-version response" "$cdir/main.err" || die "scalar .data version response must abort"

# Reuse detection works in BOTH real envelopes.
setup_case absence-versions-flat-envelope
make_prev_versions_only_fixture flat > "$cdir/versions.json"
run_case main "$verify_script"
expect_fail main
grep -qi "historical versions or a delete marker" "$cdir/main.err" || die "flat-envelope version reuse must be refused"

# An empty version history is absence and the run proceeds normally, in BOTH
# real empty shapes: the rendered {"prefixes":[]} (no data key — the CLI's
# actual empty output, the stub default everywhere) and the raw
# {"data":{"items":[]}}.
setup_case absence-versions-empty-items
make_state lin-verify 7 > "$cdir/state.json"
printf '%s' '{"prefixes":[]}' > "$cdir/versions.json"
run_case main "$verify_script"
expect_ok main
setup_case absence-versions-empty-items-raw
make_state lin-verify 7 > "$cdir/state.json"
printf '%s' '{"data":{"items":[],"prefixes":[]},"prefixes":[]}' > "$cdir/versions.json"
run_case main "$verify_script"
expect_ok main

# A reused key counts even when only its history remains.
setup_case absence-previous-versions
make_prev_versions_only_fixture > "$cdir/versions.json"
run_case main "$verify_script"
expect_fail main
grep -qi "historical versions or a delete marker" "$cdir/main.err" || die "previous-version reuse must be refused"
setup_case absence-delete-marker
make_delete_marker_only_fixture items > "$cdir/versions.json"
run_case main "$verify_script"
expect_fail main
grep -qi "historical versions or a delete marker" "$cdir/main.err" || die "delete-marker reuse must be refused"
setup_case guard-reused-key
mkdir -p "$(dirname "$cdir/bucket/$state_key")"
: > "$cdir/bucket/$state_key"
run_case main "$verify_script"
expect_fail main
grep -qi "already exists" "$cdir/main.err" || die "reused-key refusal expected"
setup_case guard-lock-present
mkdir -p "$(dirname "$cdir/bucket/$lock_key")"
: > "$cdir/bucket/$lock_key"
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

# Lock contention must fail the concurrent plan, and the failure must be a
# REAL state-lock error — an unrelated message that merely contains "lock"
# must not produce a false PASS.
setup_case fail-plan-succeeded
run_case main "$verify_script" MOCK_PLAN_HOLD_RESULT=success
expect_fail main
expect_evidence
grep -qi "expected concurrent terraform plan to fail" "$cdir/main.err" || die "unexpected plan success must be reported"
setup_case fail-plan-lock-word-only
run_case main "$verify_script" MOCK_PLAN_LOCK_ERROR=0
expect_fail main
expect_evidence
grep -qi "other than state locking" "$cdir/main.err" || die "non-lock plan failure must be reported"
if grep -qi "OCI backend initialization, remote read/write" "$cdir/main.out"; then
  die "a plan error that merely mentions 'lock' must not pass the contention gate"
fi

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
grep -qi "presence status changed" "$cdir/main.err" || die "an object appearing despite denial must stop the probe"

setup_case denied-listing-denied-unverifiable
run_case main "$denied_script" TF_OCI_PROFILE=denied-probe MOCK_INIT_FAIL=1 MOCK_LIST_FAIL=1 \
  MOCK_LIST_FAIL_MSG="ServiceError: NotAuthorizedOrNotFound"
expect_ok main
grep -qi "no absence claim is made" "$cdir/main.out" || die "denied listings must never yield an absence claim"
if grep -qi "status 'present'" "$cdir/main.out"; then
  die "unverifiable presence must not be reported as present"
fi

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
grep -qF "os object list-object-versions --bucket-name $approved_bucket --prefix $state_key --all" "$cdir/oci-calls.log" \
  || die "recovery must use the supported list-object-versions command with --all"
if grep -qE "os object list-versions " "$cdir/oci-calls.log"; then
  die "recovery must not use the unsupported list-versions command"
fi
copy_line="$(grep "os object copy" "$cdir/oci-calls.log")"
grep -qF -- "--bucket-name $approved_bucket" <<<"$copy_line" || die "copy must carry the source bucket via the required --bucket-name option"
if grep -q -- "--source-bucket" "$cdir/oci-calls.log"; then
  die "copy must never use the nonexistent --source-bucket option (CLI 3.95.1 rejects it at argument parsing)"
fi
grep -q -- "--source-version-id v-oldest" <<<"$copy_line" || die "oldest noncurrent version must be selected"
grep -q -- "--wait-for-state COMPLETED" <<<"$copy_line" || die "copy must wait for async completion"
grep -q -- "--destination-object-if-none-match-e-tag" <<<"$copy_line" || die "copy must carry the conditional none-match header"
grep -q -- "--destination-object-name $restore_key" <<<"$copy_line" || die "copy must target the restore-test prefix"
grep -q -- "--destination-region ap-hyderabad-1" <<<"$copy_line" || die "copy must pin the approved destination region"
grep -q "Restored $state_key version v-oldest to $restore_key" "$cdir/main.out" || die "restored pair must be reported"
grep -qi "byte-identical to the selected source-version snapshot" "$cdir/main.out" || die "full-snapshot verification must be reported"
grep -q "os ns get" "$cdir/oci-calls.log" || die "recovery must verify bucket preconditions too"

# The same rehearsal against the EXTENDED renderer's flattened envelope.
setup_case recovery-flat-envelope
seed_recovery_fixtures flat
make_state lin-recovery 11 > "$cdir/state.json"
run_case main "$recovery_script"
expect_ok main
grep -qF -- "--source-version-id v-oldest" "$cdir/oci-calls.log" || die "flat-envelope rehearsal must select the oldest noncurrent version"

setup_case recovery-explicit-version
seed_recovery_fixtures
make_state lin-recovery 12 > "$cdir/state.json"
run_case main "$recovery_script" TF_RESTORE_VERSION_ID=v-old
expect_ok main
copy_line="$(grep "os object copy" "$cdir/oci-calls.log")"
grep -q -- "--source-version-id v-old" <<<"$copy_line" || die "explicit version must be honored"

setup_case recovery-destination-present
seed_recovery_fixtures
mkdir -p "$(dirname "$cdir/bucket/$restore_key")"
: > "$cdir/bucket/$restore_key"
run_case main "$recovery_script"
expect_fail main
grep -qi "already exists" "$cdir/main.err" || die "occupied restore-test key must be refused"

setup_case recovery-no-noncurrent
jq -nc --arg key "$state_key" '{data:[{name:$key, size:1, etag:"e", "time-created":"2026-10-27T10:05:00Z", "time-modified":"2026-10-27T10:05:00Z", "version-id":"v-cur", "is-delete-marker":false, "storage-tier":"Standard", "archival-state":null}], prefixes:[]}' > "$cdir/versions.json"
mkdir -p "$cdir/bucket/$(dirname "$state_key")"
: > "$cdir/bucket/$state_key"
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

setup_case recovery-versions-listing-failed
seed_recovery_fixtures
run_case main "$recovery_script" MOCK_VERSIONS_FAIL=1
expect_fail main
grep -qi "unverifiable history" "$cdir/main.err" || die "failed version listing must never select a snapshot"

setup_case recovery-malformed-versions
seed_recovery_fixtures
printf '%s' '{"data":"not-an-array"}' > "$cdir/versions.json"
run_case main "$recovery_script"
expect_fail main
grep -qi "malformed object-version response" "$cdir/main.err" || die "malformed version response must abort"

setup_case recovery-malformed-items
seed_recovery_fixtures
printf '%s' '{"data":{"items":{"oops":1}}}' > "$cdir/versions.json"
run_case main "$recovery_script"
expect_fail main
grep -qi "malformed object-version response" "$cdir/main.err" || die "non-array items must abort"

setup_case recovery-copy-failed
seed_recovery_fixtures
run_case main "$recovery_script" MOCK_COPY_FAIL=1
expect_fail main
expect_evidence copy.log
grep -qi "did not complete successfully" "$cdir/main.err" || die "failed async copy must be reported"

# A concurrent writer creating the destination between the absence check and
# the copy is caught by the conditional copy header.
setup_case recovery-race-destination
seed_recovery_fixtures
make_state lin-recovery 11 > "$cdir/state.json"
run_case main "$recovery_script" MOCK_COPY_RACE=1
expect_fail main
expect_evidence copy.log
grep -qi "did not complete successfully" "$cdir/main.err" || die "raced destination creation must abort the copy"
if [[ ! -f "$cdir/bucket/$restore_key" ]]; then
  die "the stub race should have created the destination first"
fi

setup_case recovery-precondition-rejected
seed_recovery_fixtures
run_case main "$recovery_script" MOCK_COPY_PRECONDITION=1
expect_fail main
expect_evidence copy.log
grep -qi "precondition rejection" "$cdir/main.err" || die "conditional-copy rejection must be reported"

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
mkdir -p "$cdir/bucket/$(dirname "$state_key")"
: > "$cdir/bucket/$state_key"
printf 'v-cur' > "$cdir/bucket/$state_key.version"
make_state other-lineage 99 > "$cdir/wrong.json"
run_case main "$recovery_script" MOCK_COPY_CONTENT="$cdir/wrong.json"
expect_fail main
grep -qi "differs from the complete selected source-version snapshot" "$cdir/main.err" || die "restored snapshot mismatch must be reported"
expect_evidence copy.log

echo "OCI live-validation guard fixtures passed"
