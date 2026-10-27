#!/usr/bin/env bash
# Verify native OCI backend initialization with the operator's API-key profile.
# This creates only a temporary local Terraform directory and never writes a
# remote state object, resource, lock, or production backend configuration.
set -euo pipefail

: "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET.}"
: "${OCI_OBJECT_STORAGE_NAMESPACE:?Set OCI_OBJECT_STORAGE_NAMESPACE.}"
: "${OCI_REGION:?Set OCI_REGION.}"

terraform_bin="${TERRAFORM_BIN:-terraform}"
profile="${OCI_CONFIG_FILE_PROFILE:-DEFAULT}"
validation_key="${TF_BACKEND_INIT_VALIDATION_KEY:-validation/init-$(date -u +%Y%m%dT%H%M%SZ)-$$/terraform.tfstate}"

command -v "$terraform_bin" >/dev/null || { echo "Terraform is required." >&2; exit 127; }
command -v oci >/dev/null || { echo "OCI CLI is required." >&2; exit 127; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# A successful HEAD would mean a collision; a missing object is expected. The
# backend itself supplies the definitive authorization/configuration signal.
if oci os object head --bucket-name "$TF_STATE_BUCKET" --name "$validation_key" >/dev/null 2>&1; then
  echo "Disposable validation key already exists: $validation_key" >&2
  exit 1
fi

cat > "$work_dir/main.tf" <<'EOF'
terraform {
  required_version = ">= 1.12.0, < 2.0.0"
  backend "oci" {}
}
EOF

cat > "$work_dir/backend.hcl" <<EOF
bucket              = "$TF_STATE_BUCKET"
namespace           = "$OCI_OBJECT_STORAGE_NAMESPACE"
key                 = "$validation_key"
region              = "$OCI_REGION"
auth                = "APIKey"
config_file_profile = "$profile"
EOF

if ! "$terraform_bin" -chdir="$work_dir" init -input=false -backend-config=backend.hcl >"$work_dir/init.log" 2>&1; then
  if grep -qiE 'not authorized|unauthorized|forbidden|permission' "$work_dir/init.log"; then
    echo "Backend authorization failed for the operator API-key profile." >&2
  elif grep -qiE 'required|invalid|unsupported|configuration' "$work_dir/init.log"; then
    echo "Backend configuration failed before OCI authorization." >&2
  else
    echo "Backend initialization failed; inspect connectivity or OCI service diagnostics." >&2
  fi
  sed -n '1,120p' "$work_dir/init.log" >&2
  exit 1
fi

if oci os object head --bucket-name "$TF_STATE_BUCKET" --name "$validation_key" >/dev/null 2>&1; then
  echo "Backend initialization unexpectedly wrote a disposable state object." >&2
  exit 1
fi

echo "Native OCI backend initialized with APIKey profile '$profile'; no remote state object was written."
echo "Disposable validation key confirmed absent: $validation_key"
