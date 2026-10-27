#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$repo_root/scripts/ci/inspect-oidc-claims.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

mkdir -p "$temp_dir/bin"
cat > "$temp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
if [[ "$url" == https://api.github.com/repos/* ]]; then
  if [[ "${MOCK_GH_API_FAIL:-false}" == true ]]; then
    exit 22
  fi
  printf '{"id":%s,"owner":{"id":%s,"login":"eswrops"}}\n' "${MOCK_GH_REPO_ID:-1434990962}" "${MOCK_GH_OWNER_ID:-237514587}"
  exit 0
fi
printf '{"value":"%s"}\n' "${MOCK_OIDC_TOKEN:?}"
EOF
chmod +x "$temp_dir/bin/curl"

make_jwt() {
  local claims="$1"
  local header payload
  header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=\n' | tr '+/' '-_')"
  payload="$(printf '%s' "$claims" | base64 | tr -d '=\n' | tr '+/' '-_')"
  printf '%s.%s.signature' "$header" "$payload"
}

now="$(date +%s)"
valid_claims="$(jq -nc --argjson iat "$((now - 60))" --argjson exp "$((now + 3540))" '{
  iss:"https://token.actions.githubusercontent.com",
  aud:"github-actions",
  repository:"eswrops/EventForge",
  repository_id:1434990962,
  repository_owner_id:237514587,
  ref:"refs/heads/main",
  ref_type:"branch",
  environment:"production-plan",
  sub:"repo:eswrops@237514587/EventForge@1434990962:environment:production-plan",
  job_workflow_ref:"eswrops/EventForge/.github/workflows/oidc-claim-inspection.yml@refs/heads/main",
  iat:$iat,
  exp:$exp
}')"
valid_jwt="$(make_jwt "$valid_claims")"

run_helper() {
  PATH="$temp_dir/bin:$PATH" \
  MOCK_OIDC_TOKEN="${TEST_JWT:-$valid_jwt}" \
  MOCK_GH_API_FAIL="${TEST_GH_API_FAIL:-false}" \
  MOCK_GH_REPO_ID="${TEST_MOCK_REPO_ID:-1434990962}" \
  MOCK_GH_OWNER_ID="${TEST_MOCK_OWNER_ID:-237514587}" \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://github.example.test/token?request=1' \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN='github-request-token' \
  EXPECTED_ENVIRONMENT="${TEST_EXPECTED_ENV:-production-plan}" \
  EXPECTED_REPOSITORY_ID="${TEST_EXPECTED_REPO_ID:-}" \
  EXPECTED_REPOSITORY_OWNER_ID="${TEST_EXPECTED_OWNER_ID:-}" \
  GITHUB_REPOSITORY='eswrops/EventForge' \
  "$helper"
}

output="$(run_helper)"
if ! grep -q 'Result: PASS' <<<"$output"; then
  echo "Valid claims must pass inspection." >&2
  echo "$output" >&2
  exit 1
fi
if grep -Fq "$valid_jwt" <<<"$output"; then
  echo "JWT material must never appear in the inspection output." >&2
  exit 1
fi

expect_failure() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "Expected $name to fail closed." >&2
    exit 1
  fi
}

TEST_JWT="$(make_jwt "$(jq -c '."repository" = "other/repo" | ."sub" = "repo:other@1/repo@2:environment:production-plan"' <<<"$valid_claims")")" \
  expect_failure 'wrong repository claim' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."repository_id" = 999' <<<"$valid_claims")")" \
  expect_failure 'wrong numeric repository id' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."repository_owner_id" = 999' <<<"$valid_claims")")" \
  expect_failure 'wrong numeric owner id' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."environment" = "production"' <<<"$valid_claims")")" \
  expect_failure 'wrong environment claim' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."ref" = "refs/heads/feature"' <<<"$valid_claims")")" \
  expect_failure 'unexpected ref' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."ref_type" = "tag"' <<<"$valid_claims")")" \
  expect_failure 'tag ref' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."sub" = "repo:eswrops/EventForge:environment:production-plan"' <<<"$valid_claims")")" \
  expect_failure 'legacy name-only subject' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."sub" = "repo:eswrops@237514587/EventForge@999:environment:production-plan"' <<<"$valid_claims")")" \
  expect_failure 'wrong repository id inside subject' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."sub" = "repo:eswrops@999/EventForge@1434990962:environment:production-plan"' <<<"$valid_claims")")" \
  expect_failure 'wrong owner id inside subject' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."sub" = "repo:eswrops@237514587/EventForge@1434990962:ref:refs/heads/main"' <<<"$valid_claims")")" \
  expect_failure 'branch-ref subject (non-environment job)' run_helper
TEST_JWT="$(make_jwt "$(jq -c --argjson now "$now" '.exp = ($now - 10) | .iat = ($now - 3610)' <<<"$valid_claims")")" \
  expect_failure 'expired token' run_helper
TEST_JWT="$(make_jwt "$(jq -c 'del(."environment")' <<<"$valid_claims")")" \
  expect_failure 'missing environment claim' run_helper
TEST_EXPECTED_ENV='production' expect_failure 'environment mismatch on subject' run_helper

# GitHub REST identity drift must fail closed even when the JWT is self-consistent.
TEST_MOCK_REPO_ID=999999999 expect_failure 'REST repository id drift' run_helper
TEST_MOCK_OWNER_ID=999999999 expect_failure 'REST owner id drift' run_helper

# A GitHub API outage is tolerated: inspection proceeds on the verified constants.
TEST_GH_API_FAIL=true run_helper | grep -q 'Result: PASS'

# Explicitly supplied expected ids must agree with what the token presents.
TEST_EXPECTED_REPO_ID=1 TEST_EXPECTED_OWNER_ID=2 expect_failure 'explicit expected ids mismatch' run_helper
TEST_GH_API_FAIL=true TEST_EXPECTED_REPO_ID=1434990962 TEST_EXPECTED_OWNER_ID=237514587 run_helper | grep -q 'Result: PASS'

echo "OIDC claim inspection fixtures passed"
