#!/usr/bin/env bash
set -euo pipefail

# SSH-SOURCE-UPDATE safe-plan policy fixtures: exactly the reviewed one-rule
# /32 replacement is accepted; any other target, extra attribute, or resource
# change is refused.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="$repo_root/scripts/ci/platform-safe-plan-ssh-update-policy.json"
checker="$repo_root/scripts/ci/assert-safe-plan-scope-a.sh"
fixtures="$repo_root/tests/ci/fixtures"

"$checker" --policy "$policy" "$fixtures/plan-ssh-base.json"

for fixture in plan-ssh-wrong-target.json plan-ssh-extra-attr.json plan-malformed.json; do
  if "$checker" --policy "$policy" "$fixtures/$fixture" >/dev/null 2>&1; then
    echo "Expected SSH-SOURCE-UPDATE fixture $fixture to be rejected." >&2
    exit 1
  fi
done

[[ "$(jq '.allow | length' "$policy")" -eq 1 ]] || { echo "SSH policy must have exactly one allow entry." >&2; exit 1; }
jq -e '.allow[0].allowed_attribute_paths == ["source"]
   and .allow[0].actions == ["update"]
   and .allow[0].expected_attribute_values.source == "49.207.216.108/32"
   and .allow[0].expected_attribute_values_before.source == "49.207.214.221/32"' "$policy" >/dev/null \
  || { echo "SSH policy must permit only the reviewed /32 replacement." >&2; exit 1; }

echo "SSH-SOURCE-UPDATE safe-plan fixtures passed"
