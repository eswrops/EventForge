#!/usr/bin/env bash
set -euo pipefail

# Inspect the GitHub-issued OIDC JWT of the current job and require an exact
# match against the expected protected workload identity. Only sanitized claim
# values are printed; the JWT and its signature are never written anywhere.
# Any missing or mismatched claim fails closed before any federation exchange.

: "${ACTIONS_ID_TOKEN_REQUEST_URL:?GitHub id-token: write permission is required.}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?GitHub id-token: write permission is required.}"
: "${EXPECTED_ENVIRONMENT:?Set the protected environment this job must run in.}"

expected_issuer="${EXPECTED_ISSUER:-https://token.actions.githubusercontent.com}"
expected_audience="${EXPECTED_AUDIENCE:-github-actions}"
expected_repository="${EXPECTED_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
expected_ref="${EXPECTED_REF:-refs/heads/main}"
# Verified numeric identities for eswrops/EventForge (REST, M1B.1). The
# immutable subject is built from them; a rename or transfer cannot satisfy it.
expected_repository_id="${EXPECTED_REPOSITORY_ID:-1434990962}"
expected_repository_owner_id="${EXPECTED_REPOSITORY_OWNER_ID:-237514587}"

failures=0
note() { printf '%s\n' "$*"; }

record() {
  local claim="$1" status="$2" detail="${3:-}"
  if [[ "$status" == "OK" ]]; then
    note "$claim: OK ($detail)"
  else
    note "$claim: MISMATCH ($detail)"
    failures=$((failures + 1))
  fi
}

if [[ ! "$expected_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ ! "$expected_ref" =~ ^refs/ ]]; then
  note "configuration: MISMATCH (expected repository/ref not provided in a valid form)"
  exit 65
fi

token_path="$(mktemp)"
trap 'rm -f "$token_path"' EXIT
umask 077
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${expected_audience}" \
  | jq -er '.value | strings | select(length > 0)' > "$token_path"

# The payload alone is read, base64url-decoded with restored padding (BSD
# base64 silently truncates unpadded input). The signature and the encoded
# token itself are discarded here and never logged.
claims="$(cut -d. -f2 "$token_path" | tr '_-' '/+' \
  | awk '{ l = length($0); m = l % 4; if (m == 2) print $0 "=="; else if (m == 3) print $0 "="; else print }' \
  | base64 --decode 2>/dev/null || true)"
if ! jq -e 'type == "object"' <<<"$claims" >/dev/null 2>&1; then
  note "payload: MISMATCH (OIDC JWT payload was not decodable JSON)"
  exit 65
fi

# The verified numeric identities are the expected values. GitHub's REST API
# is consulted live as a second factor: if reachable, its IDs must agree with
# the expected constants — any drift (transfer, replacement repository) fails
# closed before federation is ever attempted.
api_response="$(curl --fail --silent --show-error \
  ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
  "https://api.github.com/repos/${expected_repository}" 2>/dev/null || true)"
if jq -e '(.id | type) == "number" and (.owner.id | type) == "number"' <<<"$api_response" >/dev/null 2>&1; then
  live_repo_id="$(jq -r '.id' <<<"$api_response")"
  live_owner_id="$(jq -r '.owner.id' <<<"$api_response")"
  if [[ "$live_repo_id" != "$expected_repository_id" || "$live_owner_id" != "$expected_repository_owner_id" ]]; then
    record "github-identity-drift" MISMATCH "live REST ids (repo ${live_repo_id}, owner ${live_owner_id}) differ from the verified constants"
  else
    note "github-identity-drift: OK (REST confirms repo ${live_repo_id}, owner ${live_owner_id})"
  fi
else
  note "github-identity-drift: SKIPPED (GitHub REST API unreachable; relying on verified constants)"
fi

claim_equal() {
  local name="$1" expected="$2"
  local actual
  actual="$(jq -r --arg name "$name" '.[$name] // ""' <<<"$claims")"
  if [[ "$actual" == "$expected" && -n "$expected" ]]; then
    record "$name" OK "$actual"
  else
    record "$name" MISMATCH "expected '${expected}', got '${actual:-(absent)}'"
  fi
}

now="$(date +%s)"
aud_ok="$(jq -e --arg audience "$expected_audience" '(.aud == $audience) or ((.aud | type) == "array" and any(.[]; . == $audience))' <<<"$claims" >/dev/null 2>&1 && echo yes || echo no)"
sub="$(jq -r '.sub // ""' <<<"$claims")"
job_workflow_ref="$(jq -r '.job_workflow_ref // ""' <<<"$claims")"

claim_equal iss "$expected_issuer"
if [[ "$aud_ok" == "yes" ]]; then note "audience: OK ($expected_audience)"; else record "audience" MISMATCH "expected '${expected_audience}' in aud"; fi
claim_equal repository "$expected_repository"
claim_equal environment "$EXPECTED_ENVIRONMENT"
claim_equal ref "$expected_ref"

if [[ "$(jq -r '."ref_type" // ""' <<<"$claims")" == "branch" ]]; then
  note "ref_type: OK (branch)"
else
  record "ref_type" MISMATCH "expected 'branch'"
fi

claim_equal "repository_id" "${expected_repository_id:-unavailable}"
claim_equal "repository_owner_id" "${expected_repository_owner_id:-unavailable}"

# Immutable subject: repo:<owner>@<owner_id>/<repo>@<repo_id>:environment:<env>
repo_owner="${expected_repository%%/*}"
repo_name="${expected_repository#*/}"
expected_sub="repo:${repo_owner}@${expected_repository_owner_id}/${repo_name}@${expected_repository_id}:environment:${EXPECTED_ENVIRONMENT}"
if [[ "$sub" == "$expected_sub" ]]; then
  note "subject: OK ($sub)"
else
  record "subject" MISMATCH "expected '${expected_sub}', got '${sub:-(absent)}'"
fi

if [[ "$job_workflow_ref" == *"/.github/workflows/"*"@${expected_ref}" && "$job_workflow_ref" == "${expected_repository}"* ]]; then
  note "job_workflow_ref: OK ($job_workflow_ref)"
else
  record "job_workflow_ref" MISMATCH "expected this repository's workflow at '${expected_ref}', got '${job_workflow_ref:-(absent)}'"
fi

iat="$(jq -r '.iat // 0' <<<"$claims")"
exp="$(jq -r '.exp // 0' <<<"$claims")"
if [[ "$iat" =~ ^[0-9]+$ && "$exp" =~ ^[0-9]+$ ]]; then
  if (( exp > now )) && (( iat <= now + 300 )) && (( exp - iat <= 3660 )) && (( exp <= now + 3660 )); then
    note "validity window: OK (iat/exp sane, lifetime $((exp - iat))s, expires in $((exp - now))s)"
  else
    record "validity window" MISMATCH "token expired, backdated, or has an implausible lifetime (iat=$iat exp=$exp now=$now)"
  fi
else
  record "validity window" MISMATCH "iat/exp missing or non-numeric"
fi

if (( failures > 0 )); then
  note "Result: FAIL ($failures claim(s) did not match; federation must not proceed)"
  exit 65
fi
note "Result: PASS (all expected OIDC claims matched exactly)"
