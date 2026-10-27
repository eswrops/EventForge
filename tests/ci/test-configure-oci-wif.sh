#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$repo_root/scripts/ci/configure-oci-wif.sh"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

mkdir -p "$temp_dir/bin"
cat > "$temp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter_file="${MOCK_CURL_COUNTER:?}"
count=0
[[ -f "$counter_file" ]] && count="$(<"$counter_file")"
count=$((count + 1))
printf '%s' "$count" > "$counter_file"
if [[ "$count" == 1 ]]; then
  printf '{"value":"%s"}\n' "${MOCK_OIDC_TOKEN:?}"
else
  [[ "${MOCK_EXCHANGE_FAIL:-false}" != true ]] || exit 22
  printf '{"token":"%s"}\n' "${MOCK_RPST_TOKEN:?}"
fi
EOF
cat > "$temp_dir/bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-out" ]]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
printf '%s\n' 'test-key-material' > "$out"
EOF
chmod +x "$temp_dir/bin/curl" "$temp_dir/bin/openssl"

make_jwt() {
  local claims="$1"
  local header payload
  header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=\n' | tr '+/' '-_')"
  payload="$(printf '%s' "$claims" | base64 | tr -d '=\n' | tr '+/' '-_')"
  printf '%s.%s.signature' "$header" "$payload"
}

future_exp="$(( $(date +%s) + 3600 ))"
# Immutable subject for the fixture tenant: repo:acme@555/eventforge@777:environment:production-plan
valid_claims="$(jq -nc --argjson exp "$future_exp" '{iss:"https://token.actions.githubusercontent.com",aud:"github-actions",repository:"acme/eventforge",repository_id:777,repository_owner_id:555,environment:"production-plan",sub:"repo:acme@555/eventforge@777:environment:production-plan",exp:$exp}')"
valid_jwt="$(make_jwt "$valid_claims")"
valid_rpst="$(make_jwt "$(jq -nc --argjson exp "$future_exp" '{exp:$exp}')")"
config='{"token_exchange_domain_url":"https://identity.example.test","token_exchange_client_id":"client","token_exchange_client_secret":"secret","token_exchange_resource_type":"githubactions","audience":"github-actions","repository":"acme/eventforge","repository_owner_id":"555","repository_id":"777","environment":"production-plan"}'
env_file="$temp_dir/github-env"
PATH="$temp_dir/bin:$PATH" \
MOCK_CURL_COUNTER="$temp_dir/curl-count" \
MOCK_OIDC_TOKEN="$valid_jwt" \
MOCK_RPST_TOKEN="$valid_rpst" \
OCI_WIF_CONFIG_JSON="$config" \
ACTIONS_ID_TOKEN_REQUEST_URL='https://github.example.test/token?request=1' \
ACTIONS_ID_TOKEN_REQUEST_TOKEN='github-request-token' \
OCI_REGION='ap-mumbai-1' \
RUNNER_TEMP="$temp_dir" \
GITHUB_ENV="$env_file" \
"$helper" >/dev/null

grep -Fx 'OCI_AUTH=ResourcePrincipal' "$env_file"
grep -Fx 'OCI_RESOURCE_PRINCIPAL_VERSION=2.2' "$env_file"
grep -Fx "OCI_RESOURCE_PRINCIPAL_REGION=ap-mumbai-1" "$env_file"
grep -Fqx "$valid_rpst" "$temp_dir/oci-rpst.jwt"
if grep -Fq "$valid_rpst" "$env_file"; then
  echo "RPST material must not be written to GITHUB_ENV." >&2
  exit 1
fi
# GNU stat (Linux runners) uses -c; BSD stat (macOS) uses -f for file modes.
if stat --version >/dev/null 2>&1; then
  rpst_perms="$(stat -c '%a' "$temp_dir/oci-rpst.jwt")"
else
  rpst_perms="$(stat -f '%Lp' "$temp_dir/oci-rpst.jwt")"
fi
[[ "$rpst_perms" == "600" ]]

expect_failure() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "Expected $name to fail." >&2
    exit 1
  fi
}

run_helper() {
  PATH="$temp_dir/bin:$PATH" \
  MOCK_CURL_COUNTER="$temp_dir/curl-count-$RANDOM" \
  MOCK_OIDC_TOKEN="${TEST_JWT:-$valid_jwt}" \
  MOCK_RPST_TOKEN="${TEST_RPST:-$valid_rpst}" \
  MOCK_EXCHANGE_FAIL="${TEST_EXCHANGE_FAIL:-false}" \
  OCI_WIF_CONFIG_JSON="${TEST_CONFIG:-$config}" \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://github.example.test/token?request=1' \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN='github-request-token' \
  OCI_REGION='ap-mumbai-1' RUNNER_TEMP="$temp_dir" GITHUB_ENV="$env_file" \
  "$helper"
}

TEST_CONFIG='{}' expect_failure 'missing configuration fields' run_helper
TEST_CONFIG="$(jq -c 'del(."repository_owner_id")' <<<"$config")" expect_failure 'missing repository_owner_id' run_helper
TEST_CONFIG="$(jq -c '."repository_id" = "not-a-number"' <<<"$config")" expect_failure 'non-numeric repository_id' run_helper
TEST_JWT="$(make_jwt "$(jq -nc --argjson exp "$future_exp" '{iss:"https://token.actions.githubusercontent.com",aud:"github-actions",repository:"other/repo",repository_id:777,repository_owner_id:555,environment:"production-plan",sub:"repo:other@555/repo@777:environment:production-plan",exp:$exp}')")" expect_failure 'unexpected repository claim' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."repository_id" = 999' <<<"$valid_claims")")" expect_failure 'unexpected repository id claim' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."repository_owner_id" = 999' <<<"$valid_claims")")" expect_failure 'unexpected repository owner id claim' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."sub" = "repo:acme/eventforge:environment:production-plan"' <<<"$valid_claims")")" expect_failure 'legacy name-only subject' run_helper
TEST_JWT="$(make_jwt "$(jq -c '."sub" = "repo:acme@555/eventforge@999:environment:production-plan"' <<<"$valid_claims")")" expect_failure 'wrong repository id inside subject' run_helper
TEST_JWT="$(make_jwt "$(jq -nc --argjson exp "$future_exp" '{iss:"https://token.actions.githubusercontent.com",aud:"github-actions",repository:"acme/eventforge",repository_id:777,repository_owner_id:555,environment:"production",sub:"repo:acme@555/eventforge@777:environment:production",exp:$exp}')")" expect_failure 'unexpected environment claim' run_helper
TEST_JWT="$(make_jwt "$(jq -nc --argjson exp "$((future_exp - 7200))" '{iss:"https://token.actions.githubusercontent.com",aud:"github-actions",repository:"acme/eventforge",repository_id:777,repository_owner_id:555,environment:"production-plan",sub:"repo:acme@555/eventforge@777:environment:production-plan",exp:$exp}')")" expect_failure 'expired GitHub credential' run_helper
TEST_EXCHANGE_FAIL=true expect_failure 'failed RPST exchange' run_helper
TEST_RPST="$(make_jwt "$(jq -nc --argjson exp "$((future_exp - 7200))" '{exp:$exp}')")" expect_failure 'expired RPST' run_helper

echo "WIF helper fixtures passed"
