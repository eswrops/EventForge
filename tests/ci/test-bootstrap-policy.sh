#!/usr/bin/env bash
set -euo pipefail

# Policy-string tests for the Object Storage -> KMS bootstrap policy and the
# CMK input validations. These are static: they run offline in CI and assert
# the exact verified forms, so a regression cannot reach an operator apply.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
main_tf="$repo_root/infra/bootstrap/main.tf"
variables_tf="$repo_root/infra/bootstrap/variables.tf"

assert_contains() {
  local file="$1" pattern="$2" what="$3"
  if ! grep -q "$pattern" "$file"; then
    echo "FAIL: $what not found in $file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1" pattern="$2" what="$3"
  if grep -q "$pattern" "$file"; then
    echo "FAIL: forbidden pattern found in $file: $what" >&2
    exit 1
  fi
}

# The service subject is hyphenated (objectstorage-<region>) per the OCI
# policy reference; the underscore form is a known-incorrect variant.
assert_contains "$main_tf" 'Allow service objectstorage-\${var.region} to use keys' \
  "hyphenated objectstorage-<region> service subject"
assert_not_contains "$main_tf" 'objectstorage_\${var.region}' \
  "underscore service subject"

# Key permissions are scoped to the key's own compartment and pinned to the
# exact key OCID.
assert_contains "$main_tf" 'compartment id \${var.kms_key_compartment_ocid} where target.key.id = .\${var.state_bucket_kms_key_id}.' \
  "key-compartment scope with exact target.key.id restriction"

# The key compartment is a dedicated, validated input.
assert_contains "$variables_tf" 'variable "kms_key_compartment_ocid"' \
  "kms_key_compartment_ocid variable declaration"
assert_contains "$variables_tf" 'ocid1\\\\.compartment\\\\.oc1\\\\.' \
  "compartment OCID validation for kms_key_compartment_ocid"

# The key must be from the same region as the buckets.
assert_contains "$variables_tf" 'startswith(var.state_bucket_kms_key_id, "ocid1.key.oc1.\${var.region}.")' \
  "regional compatibility validation for state_bucket_kms_key_id"

# The state bucket still pins the CMK and no bucket is public.
assert_contains "$main_tf" 'kms_key_id     = var.state_bucket_kms_key_id' \
  "state bucket CMK attachment"
assert_contains "$main_tf" 'access_type    = "NoPublicAccess"' \
  "NoPublicAccess buckets"

echo "bootstrap KMS policy-string tests passed"
