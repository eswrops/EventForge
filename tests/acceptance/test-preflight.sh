#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

validate_report() {
  local report="$1" expected_mode="$2"
  jq -e --arg mode "$expected_mode" '
    .schema_version == 1 and .read_only == true and .mode == $mode and
    (.git_commit | type == "string" and length > 0) and
    (.checks | type == "array" and length > 0) and
    (all(.checks[]; .id | type == "string" and length > 0)) and
    (all(.checks[]; .status == "PASS" or .status == "FAIL" or .status == "NOT_RUN" or .status == "BLOCKED")) and
    (.summary.fail == ([.checks[] | select(.status == "FAIL")] | length)) and
    (.summary.blocked == ([.checks[] | select(.status == "BLOCKED")] | length)) and
    ([.checks[].id] | (length == (unique | length)))
  ' "$report" >/dev/null
}

# The preflight must be runnable in CI with no GitHub or OCI session, must
# never mutate anything, and must emit a contract-valid report for every mode
# whose only failures are genuine static failures.
report="$(mktemp)"
trap 'rm -f "$report"' EXIT
for mode in pre-bootstrap post-bootstrap pre-import; do
  "$repo_root/scripts/acceptance/m1b-bootstrap-preflight.sh" \
    --mode "$mode" --skip-github --skip-oci --json "$report" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "m1b-bootstrap-preflight.sh (mode=$mode) exited ${rc}; static checks must not fail." >&2
    cat "$report" >&2
    exit 1
  fi
  validate_report "$report" "$mode"
done

# Mode-specific checks must exist: the import scope check is NOT_RUN outside
# pre-import mode; in pre-import mode it is present (its live status needs an
# OCI session, so with --skip-oci it is NOT_RUN, not BLOCKED).
"$repo_root/scripts/acceptance/m1b-bootstrap-preflight.sh" \
  --mode pre-bootstrap --skip-github --skip-oci --json "$report" >/dev/null 2>&1
jq -e '[.checks[] | select(.id == "oci-import-scope")][0].status == "NOT_RUN"' "$report" >/dev/null
"$repo_root/scripts/acceptance/m1b-bootstrap-preflight.sh" \
  --mode pre-import --skip-github --skip-oci --json "$report" >/dev/null 2>&1
jq -e '([.checks[] | select(.id == "oci-import-scope")] | length) == 1' "$report" >/dev/null
jq -e '[.checks[] | select(.id == "kms-policy-string")][0].status == "PASS"' "$report" >/dev/null

echo "bootstrap preflight report contract passed"
