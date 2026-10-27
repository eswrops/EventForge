#!/usr/bin/env bash
set -euo pipefail

# Static contract for the native OCI state backend. It deliberately performs
# no backend initialization and reads no ignored operator configuration.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

resource_has_prevent_destroy() {
  local header="$1"
  awk -v header="$header" '
    $0 == header { in_resource=1; next }
    in_resource && /^}/ { exit(found ? 0 : 1) }
    in_resource && /prevent_destroy[[:space:]]*=[[:space:]]*true/ { found=1 }
    END { if (!in_resource || !found) exit 1 }
  ' "$repo_root/infra/bootstrap/main.tf"
}

for root in bootstrap platform frontend; do
  versions="$repo_root/infra/$root/versions.tf"
  backend="$repo_root/infra/$root/backend.hcl.example"
  [[ "$(grep -cE '^[[:space:]]*backend "oci" \{\}[[:space:]]*$' "$versions")" == "1" ]] \
    || fail "$root must declare exactly one empty OCI backend"
  grep -qE '^[[:space:]]*auth[[:space:]]*=[[:space:]]*"APIKey"[[:space:]]*$' "$backend" \
    || fail "$root backend example must use the operator APIKey profile"
  grep -qE '^[[:space:]]*config_file_profile[[:space:]]*=[[:space:]]*"DEFAULT"[[:space:]]*$' "$backend" \
    || fail "$root backend example must select the DEFAULT OCI profile"
done

keys="$(grep -hE '^[[:space:]]*key[[:space:]]*=' "$repo_root"/infra/*/backend.hcl.example | sed -E 's/^[^=]*=[[:space:]]*"([^"]+)".*/\1/' | sort -u)"
expected_keys=$'bootstrap/terraform.tfstate\nfrontend/terraform.tfstate\nplatform/terraform.tfstate'
[[ "$keys" == "$expected_keys" ]] || fail "backend keys must be distinct bootstrap/platform/frontend keys"

resource_has_prevent_destroy 'resource "oci_objectstorage_bucket" "terraform_state" {' \
  || fail "state bucket must prevent Terraform-driven deletion"
resource_has_prevent_destroy 'resource "oci_objectstorage_bucket" "backups" {' \
  || fail "backup bucket must prevent Terraform-driven deletion"
resource_has_prevent_destroy 'resource "oci_identity_policy" "objectstorage_kms" {' \
  || fail "Object Storage KMS policy must prevent Terraform-driven deletion"

init_probe="$repo_root/scripts/acceptance/oci-backend-init-preflight.sh"
grep -q 'auth                = "APIKey"' "$init_probe" \
  || fail "operator backend-init probe must use APIKey authentication"
grep -q 'terraform.* init -input=false -backend-config=backend.hcl' "$init_probe" \
  || fail "operator backend-init probe must initialize the native OCI backend"
if grep -qE 'terraform.*(apply|migrate-state|force-copy)' "$init_probe"; then
  fail "operator backend-init probe must not write or migrate production state"
fi

echo "OCI backend configuration contract tests passed"
