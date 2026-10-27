#!/usr/bin/env bash
set -euo pipefail

# IAM execution guard fixtures: the reviewed two-policy create set is accepted
# exactly as contracted, and every negative variation (extra policy, missing
# policy, one-character statement change, wrong compartment, wrong name,
# unrelated extra resource, update instead of create, malformed plan) is
# refused.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
contract="$repo_root/scripts/ci/iam-plan-contract.json"
checker="$repo_root/scripts/ci/assert-iam-plan.sh"
fixtures="$repo_root/tests/ci/fixtures"

vars=(
  --var "db_compartment_ocid=ocid1.compartment.oc1..testdb"
  --var "tenancy_ocid=ocid1.tenancy.oc1..testtenancy"
)

# Positive: the reviewed change set exactly.
"$checker" --policy "$contract" "${vars[@]}" "$fixtures/plan-iam-base.json"

# The rendered statements must come out verbatim (used by m1-iam-apply.sh to
# verify the written approval record).
statements="$("$checker" --policy "$contract" "${vars[@]}" --print-statements)"
[[ "$(grep -c . <<<"$statements")" -eq 2 ]] || { echo "Expected 2 rendered statements." >&2; exit 1; }
grep -qF "in compartment id ocid1.tenancy.oc1..testtenancy where all {request.principal.type='mysqldbsystem', request.resource.compartment.id='ocid1.compartment.oc1..testdb'}" <<<"$statements" \
  || { echo "Rendered VNIC statement does not match the reviewed text." >&2; exit 1; }
# shellcheck disable=SC2016  # intentional literal ${ placeholder probe
if "$checker" --policy "$contract" "${vars[@]}" --print-statements 2>/dev/null | grep -q '\${'; then
  echo "Rendered statements must not contain unresolved placeholders." >&2
  exit 1
fi

for fixture in \
  plan-iam-extra-policy.json \
  plan-iam-missing-policy.json \
  plan-iam-wrong-statement.json \
  plan-iam-wrong-compartment.json \
  plan-iam-wrong-name.json \
  plan-iam-extra-resource.json \
  plan-iam-update-instead.json \
  plan-iam-broadened-tenancy.json \
  plan-iam-dropped-where.json \
  plan-malformed.json \
  plan-missing-resource-changes.json; do
  if "$checker" --policy "$contract" "${vars[@]}" "$fixtures/$fixture" >/dev/null 2>&1; then
    echo "Expected IAM fixture $fixture to be rejected." >&2
    exit 1
  fi
done

# The contract must pin the exact reviewed location form: a plan whose
# statement 2 uses the broader `in tenancy` keyword (b5-mysql-nsg-diagnosis.md
# §8) is refused — future contract edits cannot silently broaden the grant.
grep -qF "in compartment id \${tenancy_ocid}" "$contract" \
  || { echo "Contract must retain 'in compartment id \${tenancy_ocid}'." >&2; exit 1; }
if grep -qF "in tenancy where" "$contract"; then
  echo "Contract must not use the broader 'in tenancy' location." >&2
  exit 1
fi

# Wrong OCIDs must be refused (they render a different reviewed contract).
if "$checker" --policy "$contract" \
     --var "db_compartment_ocid=ocid1.compartment.oc1..other" \
     --var "tenancy_ocid=ocid1.tenancy.oc1..testtenancy" \
     "$fixtures/plan-iam-base.json" >/dev/null 2>&1; then
  echo "Expected wrong-compartment --var to be rejected." >&2
  exit 1
fi

# Unresolved placeholders (missing --var) must be refused.
if "$checker" --policy "$contract" \
     --var "tenancy_ocid=ocid1.tenancy.oc1..testtenancy" \
     "$fixtures/plan-iam-base.json" >/dev/null 2>&1; then
  echo "Expected missing --var to be rejected." >&2
  exit 1
fi

echo "IAM execution guard fixtures passed"
