#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
stub="$repo_root/tests/acceptance/fixtures/gh-stub.sh"
report="$(mktemp)"
trap 'rm -f "$report"' EXIT

assert_env_status() {
  local scenario="$1" expected="$2" env_name="production-plan"
  PREFLIGHT_SCENARIO="$scenario" PREFLIGHT_GH_STUB="$stub" \
    "$repo_root/scripts/acceptance/m1b-bootstrap-preflight.sh" \
    --mode pre-bootstrap --skip-oci --json "$report" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "preflight (scenario=$scenario) exited ${rc}; stubbed GitHub checks must not FAIL." >&2
    cat "$report" >&2
    exit 1
  fi
  local status
  status="$(jq -r --arg name "gh-environment-$env_name" \
    '[.checks[] | select(.id == $name)][0].status' "$report")"
  if [[ "$status" != "$expected" ]]; then
    echo "scenario '$scenario': expected gh-environment-$env_name = $expected, got $status" >&2
    jq -r --arg name "gh-environment-$env_name" \
      '[.checks[] | select(.id == $name)][0].detail' "$report" >&2
    exit 1
  fi
}

# Correct reviewer with prevent_self_review disabled must PASS.
assert_env_status ok PASS
# A wrong reviewer ID must BLOCK (never PASS with a mismatched approver).
assert_env_status wrong-reviewer BLOCKED
# Self-review prevention enabled would deadlock the solo-operator model: BLOCK.
assert_env_status self-review BLOCKED

# The production environment is evaluated with the same rules.
PREFLIGHT_SCENARIO=ok PREFLIGHT_GH_STUB="$stub" \
  "$repo_root/scripts/acceptance/m1b-bootstrap-preflight.sh" \
  --mode pre-bootstrap --skip-oci --json "$report" >/dev/null 2>&1
jq -e --arg name "gh-environment-production" \
  '[.checks[] | select(.id == $name)][0].status == "PASS"' "$report" >/dev/null

echo "preflight environment protection fixtures passed"
