#!/usr/bin/env bash
set -euo pipefail

# Guards the branch-protection contract: the four required CI checks must run
# for EVERY pull request targeting main, including docs-only PRs, and the
# workflow may only reference actions from the reviewed allowlist.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
wf="$repo_root/.github/workflows/terraform.yml"
allowlist="$repo_root/scripts/ci/action-allowlist.json"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. The pull_request trigger must be unconditional: no path filter may allow
#    a PR to skip a required check.
on_block="$(sed -n '/^on:/,/^jobs:/p' "$wf")"
grep -q '^on:' <<<"$on_block" || fail "on: trigger block not found in terraform.yml"
if grep -qE '^[[:space:]]*paths:' <<<"$on_block"; then
  fail "terraform.yml filters pull_request by paths; required checks could be skipped"
fi
grep -q 'pull_request:' <<<"$on_block" || fail "pull_request trigger missing"

# 2. The job names are the required-check contexts and must not drift.
grep -Fq 'name: Format and validate (${{ matrix.root }})' "$wf" \
  || fail "validate job name drifted"
grep -Fq 'name: CI script and workflow checks' "$wf" \
  || fail "ci-scripts job name drifted"
matrix_roots="$(sed -n 's/^[[:space:]]*root:[[:space:]]*\[\(.*\)\]$/\1/p' "$wf" | tr -d ' ')"
[[ "$matrix_roots" == "infra/bootstrap,infra/platform,infra/frontend,infra/iam" ]] \
  || fail "matrix roots drifted: '$matrix_roots'"

# 3. PR validation stays credential-free: checkout must not persist the
#    GITHUB_TOKEN on the runner.
persist_count="$(grep -c 'persist-credentials: false' "$wf" || true)"
[[ "$persist_count" == "2" ]] \
  || fail "expected persist-credentials: false on both checkout steps, found $persist_count"

# 4. Every action reference across all workflows must be an exact entry of
#    the reviewed allowlist (owner/repo@full-SHA).
while IFS= read -r ref; do
  [[ -n "$ref" ]] || continue
  if ! jq -e --arg ref "$ref" '.actions | has($ref)' "$allowlist" >/dev/null; then
    fail "workflow references action outside the allowlist: $ref"
  fi
done < <(grep -hoE 'uses: [^[:space:]]+' "$repo_root"/.github/workflows/*.yml | sed 's/^uses: //' | sort -u)

# 5. Every allowlisted reference must be a full 40-hex commit SHA.
while IFS= read -r key; do
  [[ "$(grep -oE '@[0-9a-f]{40}$' <<<"$key")" ]] || fail "allowlist entry is not SHA-pinned: $key"
done < <(jq -r '.actions | keys[]' "$allowlist")

echo "required-checks and action-allowlist contract passed"
