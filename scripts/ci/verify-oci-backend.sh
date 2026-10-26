#!/usr/bin/env bash
set -euo pipefail

# Exercise OCI backend initialization, a state write, and lock contention on a
# disposable key. Run only after configure-oci-wif.sh has exported the RPST
# environment variables. This script creates no OCI infrastructure resources.

: "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET.}"
: "${OCI_OBJECT_STORAGE_NAMESPACE:?Set OCI_OBJECT_STORAGE_NAMESPACE.}"
: "${OCI_REGION:?Set OCI_REGION.}"

command -v terraform >/dev/null || { echo "terraform is required." >&2; exit 127; }

validation_key="${TF_BACKEND_VALIDATION_KEY:-validation/$(date -u +%Y%m%dT%H%M%SZ)-$$/terraform.tfstate}"
work_dir="$(mktemp -d)"
first_output="$work_dir/first-apply.log"
second_output="$work_dir/second-plan.log"
trap 'rm -rf "$work_dir"' EXIT

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
bucket    = "$TF_STATE_BUCKET"
namespace = "$OCI_OBJECT_STORAGE_NAMESPACE"
key       = "$validation_key"
region    = "$OCI_REGION"
auth      = "ResourcePrincipal"
EOF

terraform -chdir="$work_dir" init -input=false -backend-config=backend.hcl
terraform -chdir="$work_dir" apply -input=false -auto-approve >"$first_output" 2>&1 &
first_pid=$!

lock_observed=false
for _ in $(seq 1 30); do
  if grep -q 'local-exec' "$first_output" 2>/dev/null; then
    lock_observed=true
    break
  fi
  if ! kill -0 "$first_pid" 2>/dev/null; then
    wait "$first_pid"
    echo "The lock probe ended before lock contention could be checked." >&2
    exit 1
  fi
  sleep 1
done

if [[ "$lock_observed" != true ]]; then
  wait "$first_pid"
  echo "Timed out waiting for the lock probe to acquire the Terraform state lock." >&2
  exit 1
fi

if terraform -chdir="$work_dir" plan -input=false -lock-timeout=1s >"$second_output" 2>&1; then
  echo "Expected concurrent Terraform plan to fail while the backend lock was held." >&2
  exit 1
fi
if ! grep -qi 'lock' "$second_output"; then
  echo "Concurrent Terraform plan failed for a reason other than state locking." >&2
  sed -n '1,120p' "$second_output" >&2
  exit 1
fi

wait "$first_pid"
terraform -chdir="$work_dir" state pull > "$work_dir/remote-state.json"
if ! jq -e '.resources[]? | select(.type == "terraform_data" and .name == "lock_probe")' "$work_dir/remote-state.json" >/dev/null; then
  echo "The disposable state key could not be read back after its write." >&2
  exit 1
fi
terraform -chdir="$work_dir" destroy -input=false -auto-approve

# A post-destroy plan must acquire the released lock. It is deliberately not
# applied, so the isolated key remains the only object touched by this probe.
terraform -chdir="$work_dir" plan -input=false -lock-timeout=1s > "$work_dir/released-lock-plan.log"

echo "OCI backend initialization, remote read/write, lock contention, and lock release passed."
echo "Validation state key retained for operator review: $validation_key"
