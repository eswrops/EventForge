#!/usr/bin/env bash
set -euo pipefail

# MYSQL-NSG-RETEST safe-plan policy fixtures: the dedicated one-entry policy
# (oci_mysql_mysql_db_system.existing, update, nsg_ids only, [] →
# eventforge-db-nsg) is accepted exactly as reviewed, and every negative
# variation is refused. The general M1-LOCAL policy and the four-resource
# scope-A policy are NOT modified by this gate.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="$repo_root/scripts/ci/platform-safe-plan-mysql-retest-policy.json"
checker="$repo_root/scripts/ci/assert-safe-plan-scope-a.sh"
fixtures="$repo_root/tests/ci/fixtures"

# Positive: the reviewed change set exactly.
"$checker" --policy "$policy" "$fixtures/plan-mysql-retest-base.json"

for fixture in \
  plan-mysql-retest-other-attr.json \
  plan-mysql-retest-unknown-attr.json \
  plan-mysql-retest-unknown-nsg.json \
  plan-mysql-retest-missing-change.json \
  plan-mysql-retest-replacement.json \
  plan-mysql-retest-wrong-nsg.json \
  plan-mysql-retest-prior-membership.json \
  plan-mysql-retest-attribute-removed.json \
  plan-mysql-retest-other-resource.json \
  plan-mysql-retest-security-list.json \
  plan-mysql-retest-ingress.json \
  plan-malformed.json \
  plan-missing-resource-changes.json; do
  if "$checker" --policy "$policy" "$fixtures/$fixture" >/dev/null 2>&1; then
    echo "Expected MYSQL-NSG-RETEST fixture $fixture to be rejected." >&2
    exit 1
  fi
done

# The dedicated policy carries exactly ONE allow entry — the MySQL DB system.
[[ "$(jq '.allow | length' "$policy")" -eq 1 ]] || { echo "Retest policy must have exactly one allow entry." >&2; exit 1; }
jq -e '.allow[0].allowed_attribute_paths == ["nsg_ids"]
   and .allow[0].actions == ["update"]
   and .allow[0].expected_attribute_values_before.nsg_ids == []' "$policy" >/dev/null \
  || { echo "Retest policy must permit only the nsg_ids update." >&2; exit 1; }

# The general M1-LOCAL and scope-A policies are untouched by this gate.
git -C "$repo_root" diff --exit-code -- scripts/ci/platform-safe-plan-policy.json >/dev/null \
  || { echo "The general M1-LOCAL safe-plan policy must not be modified." >&2; exit 1; }
git -C "$repo_root" diff --exit-code -- scripts/ci/platform-safe-plan-scope-a-policy.json >/dev/null \
  || { echo "The scope-A policy must not be modified." >&2; exit 1; }

echo "MYSQL-NSG-RETEST safe-plan fixtures passed"
