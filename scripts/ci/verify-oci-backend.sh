#!/usr/bin/env bash
set -euo pipefail

# Live OCI backend validation: initialization, an isolated state write, real
# lock contention, release, and re-acquisition on ONE disposable key derived
# from a mandatory RUN_ID. Runs under the explicit TF_OCI_AUTH selection with
# the pinned Terraform from TERRAFORM_BIN and fails closed on any deviation
# from the approved backend coordinates (see
# docs/acceptance/m1-final/live-backend-validation-approval.md). This script
# creates no OCI infrastructure resources, never deletes any object, and never
# removes a lock: a surviving lock is reported for a separate scoped approval.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib-oci-validation.sh
source "$repo_root/scripts/ci/lib-oci-validation.sh"

command -v oci >/dev/null || { echo "oci CLI is required." >&2; exit 127; }

vf_require_validation_keys
vf_require_approved_backend
vf_require_terraform
vf_require_auth

# Nothing may be written before the exact destination key and its lock key are
# proven absent.
vf_require_key_absent "Destination state key" "$VALIDATION_STATE_KEY"
vf_require_key_absent "Destination lock key" "$VALIDATION_LOCK_KEY"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/eventforge-live-validation.XXXXXX")"
evidence_dir="${TF_VALIDATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/eventforge-validation-evidence}/${VALIDATION_RUN_ID}-$(date -u +%Y%m%dT%H%M%SZ)"
first_pid=""

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

# A background Terraform apply must never outlive this script unnoticed: reap
# it on every exit path and force a failure exit if it was still running.
vf_reap_background_apply() {
  [[ -n "$first_pid" ]] || return 0
  kill -0 "$first_pid" 2>/dev/null || return 0
  echo "Reaping the background Terraform apply (pid $first_pid); it must not outlive this script." >&2
  kill -TERM "$first_pid" 2>/dev/null || true
  waited=0
  while kill -0 "$first_pid" 2>/dev/null && (( waited < 10 )); do
    sleep 1
    waited=$((waited + 1))
  done
  kill -KILL "$first_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
  return 1
}

on_exit() {
  rc=$?
  if ! vf_reap_background_apply; then
    [[ "$rc" -ne 0 ]] || rc=1
  fi
  if (( rc != 0 )); then
    vf_preserve_evidence
  else
    rm -rf "$work_dir"
  fi
  exit "$rc"
}
trap on_exit EXIT

on_signal() {
  echo "Validation interrupted by a signal; the temporary root will be preserved as evidence." >&2
  exit 130
}
trap on_signal INT TERM

cat > "$work_dir/main.tf" <<'EOF'
terraform {
  required_version = ">= 1.12.0, < 2.0.0"
  backend "oci" {}
}

resource "terraform_data" "lock_probe" {
  provisioner "local-exec" {
    command = "sleep 15"
  }
}
EOF

cat > "$work_dir/backend.hcl" <<EOF
bucket    = "$VALIDATION_LIB_APPROVED_BUCKET"
namespace = "$VALIDATION_LIB_APPROVED_NAMESPACE"
key       = "$VALIDATION_STATE_KEY"
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
    # Literal kept for the offline oci-backend-safety acceptance check.
    echo 'auth                = "ResourcePrincipal"' >> "$work_dir/backend.hcl"
    ;;
esac

"$VALIDATION_TERRAFORM" -chdir="$work_dir" init -input=false -backend-config=backend.hcl >"$work_dir/init.log" 2>&1

workspace="$("$VALIDATION_TERRAFORM" -chdir="$work_dir" workspace show)"
if [[ "$workspace" != "default" ]]; then
  echo "Terraform selected workspace '$workspace'; the approved package only covers the default workspace." >&2
  exit 1
fi

"$VALIDATION_TERRAFORM" -chdir="$work_dir" apply -input=false -auto-approve >"$work_dir/first-apply.log" 2>&1 &
first_pid=$!

# The remote lock object appearing is the definitive signal that Terraform
# holds the state lock; record its exact name for the federation policy's
# lock-object pattern.
lock_observed=false
for _ in $(seq 1 30); do
  if oci "${VALIDATION_OCI_ARGS[@]}" os object head \
      --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$VALIDATION_LOCK_KEY" >/dev/null 2>&1; then
    lock_observed=true
    break
  fi
  if ! kill -0 "$first_pid" 2>/dev/null; then
    apply_rc=0
    wait "$first_pid" || apply_rc=$?
    if (( apply_rc != 0 )); then
      echo "The background Terraform apply failed before lock contention could be checked." >&2
      tail -n 40 "$work_dir/first-apply.log" >&2 || true
    else
      echo "The background Terraform apply finished before the remote lock object could be observed; the contention check never ran." >&2
    fi
    exit 1
  fi
  sleep 1
done

if [[ "$lock_observed" != true ]]; then
  if kill -0 "$first_pid" 2>/dev/null; then
    kill -TERM "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
  fi
  echo "Timed out waiting for the remote lock object $VALIDATION_LOCK_KEY to appear." >&2
  exit 1
fi
echo "Observed lock object while held: $VALIDATION_LOCK_KEY"

if "$VALIDATION_TERRAFORM" -chdir="$work_dir" plan -input=false -lock-timeout=1s >"$work_dir/second-plan.log" 2>&1; then
  echo "Expected concurrent Terraform plan to fail while the backend lock was held." >&2
  exit 1
fi
if ! grep -qi 'lock' "$work_dir/second-plan.log"; then
  echo "Concurrent Terraform plan failed for a reason other than state locking." >&2
  sed -n '1,120p' "$work_dir/second-plan.log" >&2
  exit 1
fi

if ! wait "$first_pid"; then
  echo "The background Terraform apply failed after the contention check." >&2
  tail -n 40 "$work_dir/first-apply.log" >&2
  exit 1
fi
first_pid=""

"$VALIDATION_TERRAFORM" -chdir="$work_dir" state pull > "$work_dir/remote-state.json"
if ! jq -e '.resources[]? | select(.type == "terraform_data" and .name == "lock_probe")' "$work_dir/remote-state.json" >/dev/null; then
  echo "The disposable state key could not be read back after its write." >&2
  exit 1
fi

if ! "$VALIDATION_TERRAFORM" -chdir="$work_dir" destroy -input=false -auto-approve >"$work_dir/destroy.log" 2>&1; then
  echo "Terraform destroy failed; the state lock may survive on $VALIDATION_LOCK_KEY." >&2
  tail -n 40 "$work_dir/destroy.log" >&2
  echo "Never remove a surviving lock automatically: deleting $VALIDATION_LOCK_KEY requires a separate scoped approval naming the exact object (see live-backend-validation-approval.md, cleanup approval boundary)." >&2
  exit 1
fi

# A post-destroy plan must acquire the released lock. It is deliberately not
# applied, so the isolated key remains the only object touched by this probe.
if ! "$VALIDATION_TERRAFORM" -chdir="$work_dir" plan -input=false -lock-timeout=1s > "$work_dir/released-lock-plan.log" 2>&1; then
  echo "Post-destroy plan could not acquire the released state lock." >&2
  sed -n '1,120p' "$work_dir/released-lock-plan.log" >&2
  echo "If $VALIDATION_LOCK_KEY survives, its deletion requires a separate scoped approval naming the exact object (see live-backend-validation-approval.md, cleanup approval boundary)." >&2
  exit 1
fi

echo "OCI backend initialization, remote read/write, lock contention, and lock release passed."
echo "Observed lock object: $VALIDATION_LOCK_KEY"
echo "Validation state key retained for operator review: $VALIDATION_STATE_KEY"
echo "Deleting it (and the restore-test prefix) is outside this script and requires a separate cleanup approval naming the RUN_ID."
