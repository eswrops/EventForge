#!/usr/bin/env bash
# shellcheck shell=bash
# Shared fail-closed guards for the live OCI backend validation scripts. Every
# helper either returns successfully after setting its documented variables or
# terminates the calling script with a diagnostic on stderr. Sourced by
# scripts/ci/verify-oci-backend.sh, scripts/ci/verify-oci-backend-denied.sh,
# and scripts/acceptance/oci-state-version-recovery.sh; the approved values
# below are owned by docs/acceptance/m1-final/live-backend-validation-approval.md
# and must only change with a new approved package.

VALIDATION_LIB_APPROVED_BUCKET="eventforge-tfstate-prod"
VALIDATION_LIB_APPROVED_NAMESPACE="axrq1dasyz3y"
VALIDATION_LIB_APPROVED_REGION="ap-hyderabad-1"
VALIDATION_LIB_REQUIRED_TERRAFORM="1.12.2"
VALIDATION_LIB_RUN_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9-]{2,63}$'
VALIDATION_LIB_FORBIDDEN_PREFIXES="bootstrap/ platform/ frontend/"

vf_fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Require RUN_ID and derive the only state key the live package may touch.
# Sets VALIDATION_RUN_ID, VALIDATION_STATE_KEY, VALIDATION_LOCK_KEY.
# An explicit TF_BACKEND_VALIDATION_KEY is accepted only when it matches the
# derived key exactly; probes against bootstrap/, platform/, or frontend/ are
# refused unconditionally.
vf_require_validation_keys() {
  VALIDATION_RUN_ID="${RUN_ID:-}"
  if [[ -z "$VALIDATION_RUN_ID" ]]; then
    vf_fail "RUN_ID is required and must identify this validation run (pattern: ${VALIDATION_LIB_RUN_ID_PATTERN})."
  fi
  if [[ ! "$VALIDATION_RUN_ID" =~ $VALIDATION_LIB_RUN_ID_PATTERN ]]; then
    vf_fail "RUN_ID '$VALIDATION_RUN_ID' does not match ${VALIDATION_LIB_RUN_ID_PATTERN}; path-traversal or ambiguous run identifiers are refused."
  fi
  VALIDATION_STATE_KEY="validation/live-acceptance-${VALIDATION_RUN_ID}/terraform.tfstate"
  # shellcheck disable=SC2034  # consumed by the scripts sourcing this library
  VALIDATION_LOCK_KEY="${VALIDATION_STATE_KEY}.lock"
  if [[ -n "${TF_BACKEND_VALIDATION_KEY:-}" && "$TF_BACKEND_VALIDATION_KEY" != "$VALIDATION_STATE_KEY" ]]; then
    vf_fail "TF_BACKEND_VALIDATION_KEY must be unset or exactly '${VALIDATION_STATE_KEY}' for RUN_ID ${VALIDATION_RUN_ID}; refusing a supplied key outside the approved live-acceptance prefix."
  fi
  case "|${VALIDATION_LIB_FORBIDDEN_PREFIXES// /|}|" in
    *"|${VALIDATION_STATE_KEY%%/*}/|"*)
      vf_fail "Production key prefix refused for validation probes: ${VALIDATION_STATE_KEY%%/*}/"
      ;;
  esac
  # Destination key for the version-restore rehearsal (recovery script only).
  # shellcheck disable=SC2034  # consumed by the scripts sourcing this library
  VALIDATION_RESTORE_KEY="validation/restore-test-${VALIDATION_RUN_ID}/terraform.tfstate"
}

# Fail closed unless every supplied backend coordinate equals the approved one.
vf_require_approved_backend() {
  [[ "${TF_STATE_BUCKET:-}" == "$VALIDATION_LIB_APPROVED_BUCKET" ]] \
    || vf_fail "TF_STATE_BUCKET must be exactly '${VALIDATION_LIB_APPROVED_BUCKET}' (got '${TF_STATE_BUCKET:-<unset>}')."
  [[ "${OCI_OBJECT_STORAGE_NAMESPACE:-}" == "$VALIDATION_LIB_APPROVED_NAMESPACE" ]] \
    || vf_fail "OCI_OBJECT_STORAGE_NAMESPACE must be exactly '${VALIDATION_LIB_APPROVED_NAMESPACE}' (got '${OCI_OBJECT_STORAGE_NAMESPACE:-<unset>}')."
  [[ "${OCI_REGION:-}" == "$VALIDATION_LIB_APPROVED_REGION" ]] \
    || vf_fail "OCI_REGION must be exactly '${VALIDATION_LIB_APPROVED_REGION}' (got '${OCI_REGION:-<unset>}')."
  if [[ -n "${TF_WORKSPACE:-}" && "$TF_WORKSPACE" != "default" ]]; then
    vf_fail "TF_WORKSPACE must be unset or 'default'; the approved package only covers the default workspace key."
  fi
}

# Resolve the explicitly configured Terraform binary and pin the version.
# Sets VALIDATION_TERRAFORM. A PATH lookup is deliberately not used: an
# unexpected binary or version aborts before any remote call.
vf_require_terraform() {
  VALIDATION_TERRAFORM="${TERRAFORM_BIN:-}"
  if [[ -z "$VALIDATION_TERRAFORM" ]]; then
    vf_fail "TERRAFORM_BIN is required; set it to the exact Terraform ${VALIDATION_LIB_REQUIRED_TERRAFORM} executable (no PATH fallback)."
  fi
  if [[ ! -x "$VALIDATION_TERRAFORM" ]]; then
    vf_fail "TERRAFORM_BIN '$VALIDATION_TERRAFORM' is not an executable file."
  fi
  local version_line
  version_line="$("$VALIDATION_TERRAFORM" version 2>/dev/null | head -n 1 || true)"
  if [[ "$version_line" != "Terraform v${VALIDATION_LIB_REQUIRED_TERRAFORM}" ]]; then
    vf_fail "Terraform ${VALIDATION_LIB_REQUIRED_TERRAFORM} is required; TERRAFORM_BIN reports '${version_line:-<no version output>}'. Refusing an unexpected binary or version."
  fi
}

# Explicit authentication selection. Sets:
#   VALIDATION_AUTH_MODE   APIKey | ResourcePrincipal
#   VALIDATION_PROFILE     profile name (APIKey mode only; empty otherwise)
#   VALIDATION_OCI_ARGS    arguments every oci CLI call must pass so the CLI
#                          identity always matches the Terraform backend one.
# OCI_CLI_PROFILE alone never selects Terraform backend credentials; in APIKey
# mode an explicit, matching TF_OCI_PROFILE is mandatory.
vf_require_auth() {
  VALIDATION_AUTH_MODE="${TF_OCI_AUTH:-}"
  VALIDATION_PROFILE=""
  case "$VALIDATION_AUTH_MODE" in
    APIKey)
      VALIDATION_PROFILE="${TF_OCI_PROFILE:-}"
      if [[ -z "$VALIDATION_PROFILE" ]]; then
        vf_fail "TF_OCI_PROFILE is required when TF_OCI_AUTH=APIKey; the Terraform backend config_file_profile is never taken from OCI_CLI_PROFILE alone."
      fi
      if [[ -n "${OCI_CLI_PROFILE:-}" && "$OCI_CLI_PROFILE" != "$VALIDATION_PROFILE" ]]; then
        vf_fail "OCI_CLI_PROFILE '${OCI_CLI_PROFILE}' conflicts with the selected backend profile '${VALIDATION_PROFILE}'."
      fi
      VALIDATION_OCI_ARGS=(--auth api_key --profile "$VALIDATION_PROFILE")
      ;;
    ResourcePrincipal)
      if [[ -z "${OCI_RESOURCE_PRINCIPAL_VERSION:-}" ]]; then
        vf_fail "TF_OCI_AUTH=ResourcePrincipal requires the RPST environment exported by scripts/ci/configure-oci-wif.sh (OCI_RESOURCE_PRINCIPAL_VERSION is unset)."
      fi
      VALIDATION_OCI_ARGS=(--auth resource_principal)
      ;;
    "")
      vf_fail "TF_OCI_AUTH is required and must be exactly APIKey or ResourcePrincipal; authentication is never implied."
      ;;
    *)
      vf_fail "TF_OCI_AUTH '${VALIDATION_AUTH_MODE}' is not supported; use APIKey or ResourcePrincipal."
      ;;
  esac
}

# Print the item array of a paginated OCI collection response, accepting — and
# only accepting — the envelopes that exist in the wild (all verified live on
# the operator workstation, OCI CLI 3.95.1): the raw collection shape
# {"data":{"items":[...]}}, the CLI-rendered flattened {"data":[...]}, and the
# CLI-rendered EMPTY listing, which omits the data key entirely and prints
# {"prefixes":[...]}. The prefixes discriminator keeps truly malformed
# documents ({}, {"nope":true}) refused, so an empty history is never claimed
# from garbage. Prints the normalized JSON array to stdout; exits non-zero on
# any unrecognized envelope.
vf_collection_items() {
  jq -c '
    (if (.data | type) == "object" then .data.items
     elif (.data | type) == "array" then .data
     elif ((.data == null) and (.prefixes | type) == "array") then []
     else error("unrecognized collection envelope") end)
    | if (type == "array") then . else error("collection items are not an array") end'
}

# Read-only bucket encryption/visibility preconditions, required before any
# live mutation: the authenticated namespace is the approved one, the bucket
# exists in it, is private, versioned, and CMK-bound with the exact expected
# key, and that CMK is still enabled. Any failure to complete these checks
# (authorization, network, malformed response) aborts the script. Requires
# TF_VALIDATION_EXPECTED_KMS_KEY_ID to name the approved state CMK and
# TF_VALIDATION_KMS_COMPARTMENT_OCID to name the compartment whose vaults hold
# it (the tenancy OCID names the root compartment).
vf_require_bucket_preconditions() {
  local expected_kms="${TF_VALIDATION_EXPECTED_KMS_KEY_ID:-}"
  local expected_comp="${TF_VALIDATION_KMS_COMPARTMENT_OCID:-}"
  if [[ -z "$expected_kms" ]]; then
    vf_fail "TF_VALIDATION_EXPECTED_KMS_KEY_ID is required: the exact approved state CMK OCID this package may operate under."
  fi
  if [[ -z "$expected_comp" ]]; then
    vf_fail "TF_VALIDATION_KMS_COMPARTMENT_OCID is required: the compartment whose vaults hold the state CMK (root compartment is the tenancy OCID)."
  fi
  case "$expected_comp" in
    ocid1.tenancy.oc1..*|ocid1.compartment.oc1..*) ;;
    *) vf_fail "TF_VALIDATION_KMS_COMPARTMENT_OCID '${expected_comp}' is not a tenancy or compartment OCID; refusing an ambiguous KMS compartment." ;;
  esac
  local actual_namespace bucket_json
  # `os ns get` returns the wrapped envelope {"data":"<namespace>"} (verified
  # live); the bare document or an unwrapped string is malformed.
  actual_namespace="$(oci "${VALIDATION_OCI_ARGS[@]}" os ns get 2>/dev/null \
      | jq -r 'if ((.data | type) == "string" and (.data | length) > 0)
                 then .data else error("missing namespace string in data") end' 2>/dev/null)" \
    || vf_fail "Could not parse the authenticated Object Storage namespace from 'os ns get' (expected {\"data\":\"<namespace>\"}); aborting without any mutation."
  if [[ "$actual_namespace" != "$VALIDATION_LIB_APPROVED_NAMESPACE" ]]; then
    vf_fail "The authenticated namespace '${actual_namespace:-<malformed>}' is not the approved '${VALIDATION_LIB_APPROVED_NAMESPACE}'."
  fi
  bucket_json="$(oci "${VALIDATION_OCI_ARGS[@]}" os bucket get \
      --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" \
      --namespace-name "$VALIDATION_LIB_APPROVED_NAMESPACE" 2>/dev/null)" \
    || vf_fail "Could not read bucket '${VALIDATION_LIB_APPROVED_BUCKET}' in '${VALIDATION_LIB_APPROVED_NAMESPACE}' (authorization, network, or missing-bucket failure); aborting without any mutation."
  if ! jq -e --arg kms "$expected_kms" '
      .data."public-access-type" == "NoPublicAccess" and
      .data."versioning" == "Enabled" and
      .data."kms-key-id" == $kms' <<<"$bucket_json" >/dev/null 2>&1; then
    vf_fail "Bucket '${VALIDATION_LIB_APPROVED_BUCKET}' does not satisfy the approved preconditions (NoPublicAccess, versioning Enabled, CMK-bound to TF_VALIDATION_EXPECTED_KMS_KEY_ID) or the response was malformed."
  fi
  vf_require_cmk_enabled "$expected_kms" "$expected_comp"
}

# The state CMK must be read through its vault's ACTUAL management endpoint:
# `kms management key get` has no regional endpoint and fails with
# "Missing option --endpoint" without one (verified live). The endpoint source
# is `kms management vault list --compartment-id ... --all`, which needs no
# endpoint itself, reading each ACTIVE vault's "management-endpoint". The key
# response is the wrapped envelope {"data":{"id":...,"lifecycle-state":...}};
# top-level id/lifecycle-state fields never occur and are refused. The key must
# be found, must equal the expected OCID, and must be ENABLED — every other
# outcome (failed vault list, no ACTIVE vault, unreachable endpoints, wrong key,
# disabled key, malformed response) aborts.
vf_require_cmk_enabled() {
  local expected_kms="$1" compartment="$2"
  local vaults_json vault_items endpoint key_json key_tsv key_id key_state found=""
  if ! vaults_json="$(oci "${VALIDATION_OCI_ARGS[@]}" kms management vault list \
      --compartment-id "$compartment" --all 2>/dev/null)"; then
    vf_fail "Could not list KMS vaults in ${compartment} (authorization, authentication, network, or pagination failure); the state CMK cannot be verified — aborting without any mutation."
  fi
  vault_items="$(vf_collection_items <<<"$vaults_json" 2>/dev/null)" \
    || vf_fail "Malformed KMS vault-list response; refusing to interpret it — aborting without any mutation."
  while IFS= read -r endpoint; do
    [[ -n "$endpoint" ]] || continue
    if ! key_json="$(oci "${VALIDATION_OCI_ARGS[@]}" kms management key get \
        --key-id "$expected_kms" --endpoint "$endpoint" 2>/dev/null)"; then
      # A foreign vault (or a transient error) reports the key as absent; the
      # found-flag check below still fails closed unless one vault returns it.
      continue
    fi
    if ! key_tsv="$(jq -r --arg want "$expected_kms" '
        (if (.data | type) == "object" then .data
         else error("unwrapped key envelope") end)
        | (if (.id | type) == "string" and (.id | length) > 0 then .id
           else error("missing key id") end) as $id
        | (if (."lifecycle-state" | type) == "string" and (."lifecycle-state" | length) > 0
           then ."lifecycle-state" else error("missing lifecycle-state") end) as $state
        | [$id, $state] | @tsv' <<<"$key_json" 2>/dev/null)"; then
      vf_fail "Malformed KMS key response from ${endpoint} (expected {\"data\":{\"id\":...,\"lifecycle-state\":...}}); refusing to interpret it — aborting without any mutation."
    fi
    key_id="${key_tsv%%$'\t'*}"
    key_state="${key_tsv#*$'\t'}"
    if [[ "$key_id" != "$expected_kms" ]]; then
      vf_fail "The vault management endpoint ${endpoint} returned key id '${key_id}' instead of the approved '${expected_kms}'; refusing to trust this endpoint — aborting."
    fi
    if [[ "$key_state" != "ENABLED" ]]; then
      vf_fail "The state CMK is not ENABLED (reported '${key_state}') via ${endpoint}; encrypted copies would fail — aborting."
    fi
    found=1
    break
  done < <(jq -r '
      .[]
      | select(."lifecycle-state" == "ACTIVE"
          and (."management-endpoint" | type) == "string"
          and (."management-endpoint" | length) > 0)
      | ."management-endpoint"' <<<"$vault_items")
  if [[ "$found" != "1" ]]; then
    vf_fail "The state CMK ${expected_kms} was not found ENABLED via any ACTIVE vault's management endpoint in ${compartment} (all lookups failed, reported a foreign key, or no ACTIVE vault with a management endpoint exists); aborting without any mutation."
  fi
}

# Fail-closed absence proof for the PRIVILEGED validation identity: two
# fully-paginated listings (--all) per key must SUCCEED, and the exact object
# name must be absent from both the current-object listing and the
# object-version listing (covering previous versions and delete markers). A
# failed listing is authorization/authentication/network/pagination trouble,
# never absence; a malformed response is refused the same way. This is the
# only absence claim the package makes.
vf_require_key_absent() {
  local label="$1" key="$2"
  local listing listing_items versions version_items names errfile
  errfile="$(mktemp -t eventforge-absence.XXXXXX)"
  if ! listing="$(oci "${VALIDATION_OCI_ARGS[@]}" os object list \
      --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" \
      --prefix "$key" --all 2>"$errfile")" ; then
    vf_fail "$label absence check failed: the object listing for '${key}' errored (authorization, authentication, network, or pagination problem), which is never treated as absence. Error tail: $(tail -n 3 "$errfile" 2>/dev/null | tr '\n' ' ')"
  fi
  listing_items="$(vf_collection_items <<<"$listing" 2>/dev/null)" \
    || vf_fail "$label absence check failed: malformed object-listing response for '${key}'; refusing to interpret it."
  if ! names="$(jq -r --arg key "$key" '
      .[] | select(."name" == $key) | ."name"' <<<"$listing_items" 2>/dev/null)"; then
    vf_fail "$label absence check failed: malformed object-listing response for '${key}'; refusing to interpret it."
  fi
  if [[ -n "$names" ]]; then
    vf_fail "$label already exists in ${VALIDATION_LIB_APPROVED_BUCKET}: ${key}. Refusing to reuse a validation key; choose a fresh RUN_ID."
  fi
  if ! versions="$(oci "${VALIDATION_OCI_ARGS[@]}" os object list-object-versions \
      --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" \
      --prefix "$key" --all 2>"$errfile")"; then
    vf_fail "$label absence check failed: the object-version listing for '${key}' errored (authorization, authentication, network, or pagination problem), which is never treated as absence. Error tail: $(tail -n 3 "$errfile" 2>/dev/null | tr '\n' ' ')"
  fi
  rm -f "$errfile"
  # The extended CLI renderer flattens the raw {"data":{"items":[...]}}
  # collection into {"data":[...]}; both are accepted, anything else is
  # malformed (never an empty history).
  version_items="$(vf_collection_items <<<"$versions" 2>/dev/null)" \
    || vf_fail "$label absence check failed: malformed object-version response for '${key}'; refusing to interpret it."
  if ! names="$(jq -r --arg key "$key" '
      .[]
      | select(."name" == $key and (."is-delete-marker" == true or ."version-id" != null))
      | ."name"' <<<"$version_items" 2>/dev/null)"; then
    vf_fail "$label absence check failed: malformed object-version response for '${key}'; refusing to interpret it."
  fi
  if [[ -n "$names" ]]; then
    vf_fail "$label has historical versions or a delete marker in ${VALIDATION_LIB_APPROVED_BUCKET}: ${key}. Refusing to reuse a validation key; choose a fresh RUN_ID."
  fi
}

# Tolerant presence probe for the future IAM-DENIAL probe's underprivileged
# identity: listings may legitimately be denied, so this NEVER claims absence
# from a failed call. Sets VALIDATION_PROBE_STATUS (consumed by the scripts
# sourcing this library) to present, absent, or unverifiable; the caller
# decides what each means. Never aborts.
# shellcheck disable=SC2034
vf_probe_key_status() {
  # shellcheck disable=SC2034  # consumed by the scripts sourcing this library
  local key="$1" listing items
  VALIDATION_PROBE_STATUS="unverifiable"
  if ! listing="$(oci "${VALIDATION_OCI_ARGS[@]}" os object list \
      --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" \
      --prefix "$key" --all 2>/dev/null)"; then
    return 0
  fi
  if ! items="$(vf_collection_items <<<"$listing" 2>/dev/null)"; then
    return 0
  fi
  if jq -e --arg key "$key" '.[] | select(."name" == $key) | .' <<<"$items" >/dev/null 2>&1; then
    VALIDATION_PROBE_STATUS="present"
  else
    VALIDATION_PROBE_STATUS="absent"
  fi
}

# The source of a version restore must exist (checked under the privileged
# identity; any failure aborts, never masquerades).
vf_require_key_present() {
  local label="$1" key="$2"
  if ! oci "${VALIDATION_OCI_ARGS[@]}" os object head \
      --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$key" >/dev/null 2>&1; then
    vf_fail "$label is absent or unreadable in ${VALIDATION_LIB_APPROVED_BUCKET}: ${key}; refusing to guess."
  fi
}
