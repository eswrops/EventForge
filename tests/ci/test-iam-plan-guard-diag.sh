#!/usr/bin/env bash
set -euo pipefail

# IAM Run Command diagnostics contract fixtures: the one-policy, read-only
# instance-principal policy is accepted exactly as reviewed, and every
# least-privilege violation is refused. This gate is independent of the
# two-policy MYSQL-NSG-IAM contract (that gate is untouched).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
contract="$repo_root/scripts/ci/iam-plan-contract-diag.json"
checker="$repo_root/scripts/ci/assert-iam-plan.sh"
fixtures="$repo_root/tests/ci/fixtures"
vars=(--var "db_compartment_ocid=ocid1.compartment.oc1..testdb" --var "tenancy_ocid=ocid1.tenancy.oc1..testtenancy")

# Positive: the reviewed change set exactly.
"$checker" --policy "$contract" "${vars[@]}" "$fixtures/plan-iam-diag-base.json"

for fixture in \
  plan-iam-diag-manage.json \
  plan-iam-diag-missing-request-cond.json \
  plan-iam-diag-missing-target-cond.json \
  plan-iam-diag-tenancy.json \
  plan-iam-diag-wrong-dg.json \
  plan-iam-diag-wrong-compartment.json \
  plan-iam-diag-resource-wrong-compartment.json \
  plan-iam-diag-second-statement.json \
  plan-iam-diag-unrelated.json; do
  if "$checker" --policy "$contract" "${vars[@]}" "$fixtures/$fixture" >/dev/null 2>&1; then
    echo "Expected IAM diagnostics fixture $fixture to be rejected." >&2
    exit 1
  fi
done

# The contract carries exactly ONE resource with the exact least-privilege
# statement: use (never manage), the execution family, the dynamic group, the
# compartment form (never tenancy), and BOTH sides of the instance condition.
[[ "$(jq '.resources | length' "$contract")" -eq 1 ]] || { echo "Diag contract must have exactly one resource." >&2; exit 1; }
stmt="$(jq -r '.resources[0].statements[0]' "$contract")"
[[ "$stmt" == "Allow dynamic-group eventforge-instances to use instance-agent-command-execution-family in compartment id \${db_compartment_ocid} where request.instance.id=target.instance.id" ]] \
  || { echo "Diag contract statement drifted from the reviewed text." >&2; exit 1; }
grep -q 'manage instance-agent-command' "$contract" \
  && { echo "Diag contract must never carry a manage verb." >&2; exit 1; } || true
grep -qE 'in tenancy|all-resources' "$contract" \
  && { echo "Diag contract must never be tenancy-wide." >&2; exit 1; } || true
jq -e '.resources[0].statements | length == 1' "$contract" >/dev/null \
  || { echo "Diag contract must carry exactly one statement." >&2; exit 1; }

echo "IAM Run Command diagnostics contract fixtures passed"
