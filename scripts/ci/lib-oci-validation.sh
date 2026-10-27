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

# The destination object must be absent before a live write, and its lock
# object with it; a reused key would silently append versions to a previous
# run's evidence. HEAD failures are treated as absence (Object Storage masks
# absent objects as 404 for callers without list permission; the definitive
# signal is the authorized Terraform operation itself).
vf_require_key_absent() {
  local label="$1" key="$2"
  if oci "${VALIDATION_OCI_ARGS[@]}" os object head \
      --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$key" >/dev/null 2>&1; then
    vf_fail "$label already exists in ${VALIDATION_LIB_APPROVED_BUCKET}: ${key}. Refusing to reuse a validation key; choose a fresh RUN_ID."
  fi
}

# Inverse of vf_require_key_absent: the source of a version restore must exist.
vf_require_key_present() {
  local label="$1" key="$2"
  if ! oci "${VALIDATION_OCI_ARGS[@]}" os object head \
      --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$key" >/dev/null 2>&1; then
    vf_fail "$label is absent in ${VALIDATION_LIB_APPROVED_BUCKET}: ${key}; nothing to restore from."
  fi
}
