#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="$repo_root/scripts/ci/platform-safe-plan-policy.json"
checker="$repo_root/scripts/ci/assert-safe-plan.sh"
fixtures="$repo_root/tests/ci/fixtures"

"$checker" --policy "$policy" "$fixtures/plan-allowed.json"
"$checker" --policy "$policy" "$fixtures/plan-noop.json"
"$checker" --policy "$policy" "$fixtures/plan-allowed-ingress.json"

for fixture in \
  plan-unapproved.json \
  plan-imported-update.json \
  plan-public-port.json \
  plan-delete.json \
  plan-replace-create-delete.json \
  plan-replace-delete-create.json \
  plan-unknown-ingress.json \
  plan-malformed.json \
  plan-missing-resource-changes.json; do
  if "$checker" --policy "$policy" "$fixtures/$fixture" >/dev/null 2>&1; then
    echo "Expected $fixture to be rejected." >&2
    exit 1
  fi
done

temp_policy="$(mktemp)"
temp_plan="$(mktemp)"
trap 'rm -f "$temp_policy" "$temp_plan"' EXIT
jq '.allow += [{"address_regex":"^terraform_data\\.api_origin_generation$","actions":["update"]}]' "$policy" > "$temp_policy"
printf '%s\n' '{"resource_changes":[{"address":"terraform_data.api_origin_generation","type":"terraform_data","change":{"actions":["update"],"after":{}}}]}' > "$temp_plan"
if "$checker" --policy "$policy" "$temp_plan" >/dev/null 2>&1; then
  echo "Expected an unreviewed certificate-generation update to be rejected." >&2
  exit 1
fi
"$checker" --policy "$temp_policy" "$temp_plan"

echo "safe-plan fixtures passed"
