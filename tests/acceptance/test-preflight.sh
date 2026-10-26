#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
report="$(mktemp)"
trap 'rm -f "$report"' EXIT

# The preflight must be runnable in CI with no GitHub or OCI session, must
# never mutate anything, and must emit a contract-valid report whose only
# failures are genuine static failures.
"$repo_root/scripts/acceptance/m1b-bootstrap-preflight.sh" --skip-github --skip-oci --json "$report" >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "m1b-bootstrap-preflight.sh exited ${rc}; static checks must not fail." >&2
  cat "$report" >&2
  exit 1
fi

jq -e '
  .schema_version == 1 and .read_only == true and
  (.git_commit | type == "string" and length > 0) and
  (.checks | type == "array" and length > 0) and
  (all(.checks[]; .id | type == "string" and length > 0)) and
  (all(.checks[]; .status == "PASS" or .status == "FAIL" or .status == "NOT_RUN" or .status == "BLOCKED")) and
  (.summary.fail == ([.checks[] | select(.status == "FAIL")] | length)) and
  (.summary.blocked == ([.checks[] | select(.status == "BLOCKED")] | length)) and
  ([.checks[].id] | (length == (unique | length)))
' "$report" >/dev/null

echo "bootstrap preflight report contract passed"
