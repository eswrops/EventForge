#!/usr/bin/env bash
set -euo pipefail

: "${OCI_WIF_CONFIG_JSON:?Set OCI_WIF_CONFIG_JSON in the protected production environment.}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?GitHub OIDC permission is required.}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?GitHub OIDC permission is required.}"

token_path="$RUNNER_TEMP/oci-github-oidc.jwt"
config_path="$RUNNER_TEMP/oci-wif-config.json"
audience="github-actions"

curl --fail --silent --show-error \
  -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" \
  | jq -er '.value' > "$token_path"
chmod 0600 "$token_path"

# The protected secret is the current OCI SDK WIF JSON supplied by the tenancy
# administrator. Keeping it as JSON avoids committing identity-domain fields
# that differ across tenancies. Inject only the short-lived GitHub JWT path.
jq --arg token_path "$token_path" '.workload_identity_token_path = $token_path' \
  <<<"$OCI_WIF_CONFIG_JSON" > "$config_path"
chmod 0600 "$config_path"

echo "OCI_CONFIG_FILE=$config_path" >> "$GITHUB_ENV"
echo "OCI_RESOURCE_PRINCIPAL_VERSION=2.2" >> "$GITHUB_ENV"

