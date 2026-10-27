#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
report="$(mktemp)"
trap 'rm -f "$report"' EXIT

"$repo_root/scripts/acceptance/run.sh" --report "$report"
jq -e '
  .schema_version == 1 and .offline == true and
  (.checks | type == "array" and length > 0) and
  all(.checks[]; (.status == "PASS" or .status == "FAIL" or .status == "NOT_RUN")) and
  (.summary.not_run == ([.checks[] | select(.status == "NOT_RUN")] | length))
' "$report" >/dev/null

echo "acceptance runner report contract passed"

# The M1B.1 bootstrap preflight must run read-only with no live sessions.
"$repo_root/tests/acceptance/test-preflight.sh"

# Environment protection detection must be exercised against fixture GitHub
# responses (correct reviewer / wrong reviewer / self-review prevention).
"$repo_root/tests/acceptance/test-preflight-github.sh"
