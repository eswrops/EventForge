#!/usr/bin/env bash
set -euo pipefail

# Scope-A safe-plan checker fixtures: the four-address NSG-association change
# set is accepted exactly as reviewed, and every negative variation
# (extra address, non-NSG attribute, replacement, wrong NSG value, unknown
# attribute, dropped change, non-empty prior membership, removed attribute)
# is refused.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="$repo_root/scripts/ci/platform-safe-plan-scope-a-policy.json"
checker="$repo_root/scripts/ci/assert-safe-plan-scope-a.sh"
general_checker="$repo_root/scripts/ci/assert-safe-plan.sh"
general_policy="$repo_root/scripts/ci/platform-safe-plan-policy.json"
fixtures="$repo_root/tests/ci/fixtures"

# Positive: the reviewed change set exactly.
"$checker" --policy "$policy" "$fixtures/plan-scopea-base.json"

# The general M1-LOCAL policy still refuses the same plan's protected-import
# updates (scope A never relaxes the general gate).
if "$general_checker" --policy "$general_policy" "$fixtures/plan-scopea-base.json" >/dev/null 2>&1; then
  echo "Expected the general policy to refuse a scope-A plan (protected imports)." >&2
  exit 1
fi

for fixture in \
  plan-scopea-extra-address.json \
  plan-scopea-non-nsg-attr.json \
  plan-scopea-replacement.json \
  plan-scopea-wrong-nsg.json \
  plan-scopea-unknown-attr.json \
  plan-scopea-missing-change.json \
  plan-scopea-prior-membership.json \
  plan-scopea-attribute-removed.json \
  plan-malformed.json \
  plan-missing-resource-changes.json; do
  if "$checker" --policy "$policy" "$fixtures/$fixture" >/dev/null 2>&1; then
    echo "Expected scope-A fixture $fixture to be rejected." >&2
    exit 1
  fi
done

echo "scope-A safe-plan fixtures passed"
