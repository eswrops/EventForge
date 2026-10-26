#!/usr/bin/env bash
# Run manually with a deliberately underprivileged OCI identity. This script
# must fail backend initialization; it never creates a state object or resource.
set -euo pipefail

: "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET.}"
: "${OCI_OBJECT_STORAGE_NAMESPACE:?Set OCI_OBJECT_STORAGE_NAMESPACE.}"
: "${OCI_REGION:?Set OCI_REGION.}"
: "${TF_BACKEND_VALIDATION_KEY:?Set the disposable validation key to probe.}"

command -v terraform >/dev/null || { echo "terraform is required." >&2; exit 127; }

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
cat > "$work_dir/main.tf" <<'EOF'
terraform {
  required_version = ">= 1.12.0, < 2.0.0"
  backend "oci" {}
}
EOF
cat > "$work_dir/backend.hcl" <<EOF
bucket    = "$TF_STATE_BUCKET"
namespace = "$OCI_OBJECT_STORAGE_NAMESPACE"
key       = "$TF_BACKEND_VALIDATION_KEY"
region    = "$OCI_REGION"
auth      = "ResourcePrincipal"
EOF

if terraform -chdir="$work_dir" init -input=false -backend-config=backend.hcl > "$work_dir/init.log" 2>&1; then
  echo "Expected the underprivileged identity to be denied state-bucket access." >&2
  exit 1
fi

if ! grep -qiE 'denied|not authorized|forbidden|unauthorized' "$work_dir/init.log"; then
  echo "Backend initialization failed for a reason other than an authorization denial." >&2
  sed -n '1,120p' "$work_dir/init.log" >&2
  exit 1
fi

echo "Underprivileged identity was denied access to the disposable Terraform state key."
