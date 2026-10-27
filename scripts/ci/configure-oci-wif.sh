#!/usr/bin/env bash
set -euo pipefail

# Exchange a GitHub OIDC JWT for an OCI Resource Principal Session Token
# (RPST) bound to a one-run keypair. Terraform consumes only the temporary
# ResourcePrincipal paths written below; this script never prints token data.

: "${OCI_WIF_CONFIG_JSON:?Set OCI_WIF_CONFIG_JSON in the protected GitHub environment.}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?GitHub id-token: write permission is required.}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?GitHub id-token: write permission is required.}"
: "${OCI_REGION:?Set OCI_REGION in the protected GitHub environment.}"
: "${RUNNER_TEMP:?This script must run on a GitHub Actions runner.}"
: "${GITHUB_ENV:?This script must run in a GitHub Actions step.}"

config_field() {
  local field="$1"
  jq -er --arg field "$field" '.[$field] | strings | select(length > 0)' <<<"$OCI_WIF_CONFIG_JSON"
}

numeric_config_field() {
  local field="$1"
  jq -er --arg field "$field" '.[$field] | tostring | select(test("^[0-9]+$"))' <<<"$OCI_WIF_CONFIG_JSON"
}

domain_url="$(config_field token_exchange_domain_url)"
client_id="$(config_field token_exchange_client_id)"
client_secret="$(config_field token_exchange_client_secret)"
resource_type="$(config_field token_exchange_resource_type)"
audience="$(jq -er '.audience // "github-actions" | strings | select(length > 0)' <<<"$OCI_WIF_CONFIG_JSON")"
expected_repository="$(config_field repository)"
expected_environment="$(config_field environment)"
# Immutable numeric identities; the subject is built from them so a repository
# rename or transfer can never satisfy this trust.
repository_owner_id="$(numeric_config_field repository_owner_id)"
repository_id="$(numeric_config_field repository_id)"
expected_issuer="$(jq -er '.issuer // "https://token.actions.githubusercontent.com" | strings | select(length > 0)' <<<"$OCI_WIF_CONFIG_JSON")"
rpst_exp="$(jq -er '.token_exchange_rpst_exp // "60" | tostring | select(test("^[0-9]+$"))' <<<"$OCI_WIF_CONFIG_JSON")"

if [[ ! "$domain_url" =~ ^https://[^[:space:]]+$ ]] || [[ "$expected_issuer" != "https://token.actions.githubusercontent.com" ]]; then
  echo "OIDC issuer and token exchange domain must be approved HTTPS URLs." >&2
  exit 64
fi
if [[ ! "$resource_type" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$audience" =~ ^[A-Za-z0-9._:./-]+$ ]]; then
  echo "OIDC resource type or audience contains unsupported characters." >&2
  exit 64
fi
if [[ ! "$expected_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ ! "$expected_environment" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "OIDC repository or environment is invalid." >&2
  exit 64
fi
if (( rpst_exp < 1 || rpst_exp > 720 )); then
  echo "token_exchange_rpst_exp must be between 1 and 720 minutes." >&2
  exit 64
fi

token_path="$RUNNER_TEMP/oci-github-oidc.jwt"
private_key_path="$RUNNER_TEMP/oci-rpst-private-key.pem"
public_key_path="$RUNNER_TEMP/oci-rpst-public-key.pem"
rpst_path="$RUNNER_TEMP/oci-rpst.jwt"

umask 077
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" \
  | jq -er '.value | strings | select(length > 0)' > "$token_path"

# Protected workflow jobs must present GitHub's immutable subject exactly:
# repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<environment>, with the
# numeric claims matching. This rejects branch, tag, pull-request,
# other-repository, renamed-repository, legacy name-only subjects,
# wrong-audience and expired tokens before they reach the exchange endpoint.
jwt_payload="$(cut -d. -f2 "$token_path" | tr '_-' '/+' \
  | awk '{ l = length($0); m = l % 4; if (m == 2) print $0 "=="; else if (m == 3) print $0 "="; else print }' \
  | base64 --decode 2>/dev/null || true)"
repo_owner="${expected_repository%%/*}"
repo_name="${expected_repository#*/}"
expected_sub="repo:${repo_owner}@${repository_owner_id}/${repo_name}@${repository_id}:environment:${expected_environment}"
if ! jq -e \
  --arg issuer "$expected_issuer" \
  --arg audience "$audience" \
  --arg repository "$expected_repository" \
  --arg environment "$expected_environment" \
  --arg sub "$expected_sub" \
  --argjson repository_owner_id "$repository_owner_id" \
  --argjson repository_id "$repository_id" '
    (.iss == $issuer) and
    ((.aud == $audience) or ((.aud | type == "array") and any(.[]; . == $audience))) and
    (.repository == $repository) and
    (.repository_id == $repository_id) and
    (.repository_owner_id == $repository_owner_id) and
    (.environment == $environment) and
    (.sub == $sub) and
    (.exp | type == "number") and (.exp > now)
  ' <<<"$jwt_payload" >/dev/null; then
  echo "GitHub OIDC claims are missing, expired, or do not match the protected workload." >&2
  exit 65
fi

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$private_key_path" >/dev/null 2>&1
openssl pkey -in "$private_key_path" -pubout -out "$public_key_path" >/dev/null 2>&1

curl --fail --silent --show-error \
  --user "${client_id}:${client_secret}" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "requested_token_type=urn:oci:token-type:oci-rpst" \
  --data-urlencode "subject_token_type=jwt" \
  --data-urlencode "subject_token@${token_path}" \
  --data-urlencode "public_key@${public_key_path}" \
  --data-urlencode "res_type=${resource_type}" \
  --data-urlencode "rpst_exp=${rpst_exp}" \
  "${domain_url%/}/oauth2/v1/token" \
  | jq -er '.token | strings | select(length > 0)' > "$rpst_path"

# OCI RPSTs are JWTs. Refuse an opaque, malformed, or already-expired token
# rather than leaving a long-running job to fail later with an ambiguous auth
# error. Jobs expected to outlive this window must re-run this helper before
# Terraform initialization/plan/apply; they must not fall back to API keys.
rpst_payload="$(cut -d. -f2 "$rpst_path" | tr '_-' '/+' \
  | awk '{ l = length($0); m = l % 4; if (m == 2) print $0 "=="; else if (m == 3) print $0 "="; else print }' \
  | base64 --decode 2>/dev/null || true)"
if ! jq -e '(.exp | type == "number") and (.exp > now)' <<<"$rpst_payload" >/dev/null; then
  echo "OCI RPST is malformed or expired." >&2
  exit 65
fi

chmod 0600 "$token_path" "$private_key_path" "$public_key_path" "$rpst_path"

{
  echo "OCI_AUTH=ResourcePrincipal"
  echo "OCI_RESOURCE_PRINCIPAL_VERSION=2.2"
  echo "OCI_RESOURCE_PRINCIPAL_RPST=$rpst_path"
  echo "OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM=$private_key_path"
  echo "OCI_RESOURCE_PRINCIPAL_REGION=$OCI_REGION"
} >> "$GITHUB_ENV"

echo "OCI GitHub workload token exchanged for a short-lived Resource Principal Session Token."

