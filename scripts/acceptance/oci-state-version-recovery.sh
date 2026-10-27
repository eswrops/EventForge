#!/usr/bin/env bash
set -euo pipefail

# State version-recovery rehearsal (STATE-RECOVERY gate) on the disposable
# RUN_ID keys only: list the real object versions with the OCI CLI's supported
# `os object list-object-versions` command, select and validate one specific
# NONCURRENT version, confirm the restore-test destination is absent, copy it
# exclusively to validation/restore-test-<RUN_ID>/ while waiting for the
# asynchronous copy to complete, and verify the restored state reads back with
# the source snapshot's lineage and serial. The production bootstrap key (and
# every other production key) is refused as a source or destination; nothing
# here ever writes over the live state object. See
# docs/acceptance/m1-final/live-backend-validation-approval.md.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../ci/lib-oci-validation.sh
source "$repo_root/scripts/ci/lib-oci-validation.sh"

command -v oci >/dev/null || { echo "oci CLI is required." >&2; exit 127; }

vf_require_validation_keys
vf_require_approved_backend
vf_require_terraform
vf_require_auth

# The only permitted source is this run's retained live-acceptance state; the
# only permitted destination is this run's restore-test key.
if [[ -n "${TF_RESTORE_SOURCE_KEY:-}" && "$TF_RESTORE_SOURCE_KEY" != "$VALIDATION_STATE_KEY" ]]; then
  vf_fail "TF_RESTORE_SOURCE_KEY must be unset or exactly '${VALIDATION_STATE_KEY}' for RUN_ID ${VALIDATION_RUN_ID}."
fi

vf_require_key_present "Source state key" "$VALIDATION_STATE_KEY"
current_version_id="$(oci "${VALIDATION_OCI_ARGS[@]}" os object head \
  --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$VALIDATION_STATE_KEY" \
  | jq -r '."version-id" // empty')"
if [[ -z "$current_version_id" ]]; then
  vf_fail "Object head reported no current version id for $VALIDATION_STATE_KEY; refusing to guess."
fi

# The list-object-versions response data items carry name, version-id,
# is-delete-marker, and time-created (there is no is-current field); the
# current version was obtained from the object head above.
versions_json="$(oci "${VALIDATION_OCI_ARGS[@]}" os object list-object-versions \
  --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --prefix "$VALIDATION_STATE_KEY")"
noncurrent_tsv="$(jq -r --arg key "$VALIDATION_STATE_KEY" --arg cur "$current_version_id" '
  [.data[]
   | select(."name" == $key and ."is-delete-marker" != true and ."version-id" != null and ."version-id" != $cur)]
  | sort_by(."time-created", ."version-id")[]
  | [."time-created", ."version-id"] | @tsv' <<<"$versions_json")"

chosen_version_id="${TF_RESTORE_VERSION_ID:-}"
chosen_version_time=""
version_found=false
while IFS="$(printf '\t')" read -r version_time version_id; do
  [[ -n "$version_id" ]] || continue
  if [[ -n "$chosen_version_id" ]]; then
    if [[ "$version_id" == "$chosen_version_id" ]]; then
      version_found=true
      chosen_version_time="$version_time"
      break
    fi
  elif [[ -z "$chosen_version_time" ]]; then
    # Default selection: the oldest noncurrent version, deterministically.
    chosen_version_time="$version_time"
    chosen_version_id="$version_id"
  fi
done <<<"$noncurrent_tsv"

if [[ -z "$chosen_version_id" ]]; then
  vf_fail "No noncurrent version of $VALIDATION_STATE_KEY is available to restore."
fi
if [[ -n "${TF_RESTORE_VERSION_ID:-}" && "$version_found" != true ]]; then
  vf_fail "TF_RESTORE_VERSION_ID '${TF_RESTORE_VERSION_ID}' is not a noncurrent version of $VALIDATION_STATE_KEY."
fi
echo "Selected noncurrent version: $chosen_version_id (created $chosen_version_time)"

vf_require_key_absent "Restore-test destination key" "$VALIDATION_RESTORE_KEY"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/eventforge-restore-test.XXXXXX")"
evidence_dir="${TF_VALIDATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/eventforge-validation-evidence}/${VALIDATION_RUN_ID}-restore-$(date -u +%Y%m%dT%H%M%SZ)"

vf_preserve_evidence() {
  mkdir -p "$evidence_dir" 2>/dev/null || true
  chmod 700 "$evidence_dir" 2>/dev/null || true
  if mv "$work_dir" "$evidence_dir/terraform-root" 2>/dev/null; then
    chmod 700 "$evidence_dir/terraform-root" 2>/dev/null || true
    echo "Evidence preserved (temporary root and logs): $evidence_dir/terraform-root" >&2
  else
    echo "Could not relocate $work_dir into $evidence_dir; preserve it manually." >&2
  fi
}

on_exit() {
  rc=$?
  if (( rc != 0 )); then
    vf_preserve_evidence
  else
    rm -rf "$work_dir"
  fi
  exit "$rc"
}
trap on_exit EXIT

on_signal() {
  echo "Recovery rehearsal interrupted by a signal; the temporary root will be preserved as evidence." >&2
  exit 130
}
trap on_signal INT TERM

# The copy is asynchronous; --wait-for-state COMPLETED makes the CLI poll the
# work request and fail unless it completes.
if ! oci "${VALIDATION_OCI_ARGS[@]}" os object copy \
    --source-bucket "$VALIDATION_LIB_APPROVED_BUCKET" \
    --source-object-name "$VALIDATION_STATE_KEY" \
    --source-version-id "$chosen_version_id" \
    --destination-bucket "$VALIDATION_LIB_APPROVED_BUCKET" \
    --destination-namespace "$VALIDATION_LIB_APPROVED_NAMESPACE" \
    --destination-region "$VALIDATION_LIB_APPROVED_REGION" \
    --destination-object-name "$VALIDATION_RESTORE_KEY" \
    --wait-for-state COMPLETED --wait-interval-seconds 5 \
    >"$work_dir/copy.log" 2>&1; then
  echo "The asynchronous object copy did not complete successfully." >&2
  sed -n '1,60p' "$work_dir/copy.log" >&2
  exit 1
fi

copy_version_id="$(oci "${VALIDATION_OCI_ARGS[@]}" os object head \
  --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$VALIDATION_RESTORE_KEY" \
  | jq -r '."version-id" // empty')" || copy_version_id=""
if [[ -z "$copy_version_id" ]]; then
  echo "The copy reported success but the restore-test key is absent or unversioned; treating the copy as incomplete." >&2
  exit 1
fi

oci "${VALIDATION_OCI_ARGS[@]}" os object get \
  --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$VALIDATION_STATE_KEY" \
  --version-id "$chosen_version_id" --file "$work_dir/source-version.tfstate" >"$work_dir/source-get.log" 2>&1
oci "${VALIDATION_OCI_ARGS[@]}" os object get \
  --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$VALIDATION_RESTORE_KEY" \
  --file "$work_dir/restored.tfstate" >"$work_dir/dest-get.log" 2>&1

state_snapshot_contract() {
  jq -e '(.lineage | type == "string" and length > 0) and
         (.serial | type == "number") and
         (.terraform_version | type == "string" and length > 0)' "$1" >/dev/null
}
if ! state_snapshot_contract "$work_dir/source-version.tfstate"; then
  echo "The selected source version is not a recognizable Terraform state snapshot." >&2
  exit 1
fi
if ! state_snapshot_contract "$work_dir/restored.tfstate"; then
  echo "The restored object is not a recognizable Terraform state snapshot." >&2
  exit 1
fi

source_lineage="$(jq -r '.lineage' "$work_dir/source-version.tfstate")"
source_serial="$(jq -r '.serial' "$work_dir/source-version.tfstate")"
restored_lineage="$(jq -r '.lineage' "$work_dir/restored.tfstate")"
restored_serial="$(jq -r '.serial' "$work_dir/restored.tfstate")"
if [[ "$source_lineage" != "$restored_lineage" || "$source_serial" != "$restored_serial" ]]; then
  echo "Restored snapshot mismatch: expected lineage '$source_lineage' serial $source_serial, got '$restored_lineage' serial $restored_serial." >&2
  exit 1
fi

# Terraform readability of the restored key through a scratch backend.
cat > "$work_dir/main.tf" <<'EOF'
terraform {
  required_version = ">= 1.12.0, < 2.0.0"
  backend "oci" {}
}
EOF
cat > "$work_dir/backend.hcl" <<EOF
bucket    = "$VALIDATION_LIB_APPROVED_BUCKET"
namespace = "$VALIDATION_LIB_APPROVED_NAMESPACE"
key       = "$VALIDATION_RESTORE_KEY"
region    = "$VALIDATION_LIB_APPROVED_REGION"
EOF
case "$VALIDATION_AUTH_MODE" in
  APIKey)
    {
      echo 'auth                = "APIKey"'
      echo "config_file_profile = \"$VALIDATION_PROFILE\""
    } >> "$work_dir/backend.hcl"
    ;;
  ResourcePrincipal)
    echo 'auth                = "ResourcePrincipal"' >> "$work_dir/backend.hcl"
    ;;
esac
"$VALIDATION_TERRAFORM" -chdir="$work_dir" init -input=false -backend-config=backend.hcl >"$work_dir/init.log" 2>&1
workspace="$("$VALIDATION_TERRAFORM" -chdir="$work_dir" workspace show)"
if [[ "$workspace" != "default" ]]; then
  echo "Terraform selected workspace '$workspace'; the approved package only covers the default workspace." >&2
  exit 1
fi
"$VALIDATION_TERRAFORM" -chdir="$work_dir" state pull > "$work_dir/pulled-state.json" 2>"$work_dir/state-pull.log"
if ! state_snapshot_contract "$work_dir/pulled-state.json"; then
  echo "terraform state pull against the restore-test key failed or returned no snapshot." >&2
  sed -n '1,60p' "$work_dir/state-pull.log" >&2
  exit 1
fi
pulled_lineage="$(jq -r '.lineage' "$work_dir/pulled-state.json")"
pulled_serial="$(jq -r '.serial' "$work_dir/pulled-state.json")"
if [[ "$pulled_lineage" != "$source_lineage" || "$pulled_serial" != "$source_serial" ]]; then
  echo "Pulled snapshot mismatch against the restore-test key." >&2
  exit 1
fi

echo "State version recovery rehearsal passed."
echo "Restored $VALIDATION_STATE_KEY version $chosen_version_id to $VALIDATION_RESTORE_KEY"
echo "Snapshot identity: lineage $source_lineage serial $source_serial"
echo "Both validation keys are retained for operator review; deletion requires a separate cleanup approval naming RUN_ID $VALIDATION_RUN_ID."
