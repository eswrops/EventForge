#!/usr/bin/env bash
set -euo pipefail

# Live authorization-denial probe: backend initialization against the RUN_ID's
# disposable validation key under a deliberately underprivileged identity MUST
# fail with an authorization denial and MUST write nothing. The privileged
# operator profile is refused up front so the probe can never accidentally run
# with it. Creating any IAM principal or API key for this probe is out of
# scope; until the federation phase provides an underprivileged principal this
# probe stays deferred (no PASS may be claimed from administrator-profile or
# mock runs). See docs/acceptance/m1-final/live-backend-validation-approval.md.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib-oci-validation.sh
source "$repo_root/scripts/ci/lib-oci-validation.sh"

command -v oci >/dev/null || { echo "oci CLI is required." >&2; exit 127; }

vf_require_validation_keys
vf_require_approved_backend
vf_require_terraform
vf_require_auth

if [[ "$VALIDATION_AUTH_MODE" == "APIKey" ]]; then
  if [[ "$VALIDATION_PROFILE" == "DEFAULT" ]]; then
    vf_fail "The denial probe must not run under the privileged DEFAULT profile; select the explicitly underprivileged profile with TF_OCI_PROFILE."
  fi
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/eventforge-denied-probe.XXXXXX")"
evidence_dir="${TF_VALIDATION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/eventforge-validation-evidence}/${VALIDATION_RUN_ID}-denied-$(date -u +%Y%m%dT%H%M%SZ)"

vf_preserve_evidence() {
  mkdir -p "$evidence_dir" 2>/dev/null || true
  chmod 700 "$evidence_dir" 2>/dev/null || true
  if mv "$work_dir" "$evidence_dir/terraform-root" 2>/dev/null; then
    chmod 700 "$evidence_dir/terraform-root" 2>/dev/null || true
    echo "Evidence preserved (temporary root and logs): $evidence_dir/terraform-root" >&2
  else
    echo "Could not relocate $work_dir into $evidence_dir; preserve it manually." >&2
  fi
}

on_exit() {
  rc=$?
  if (( rc != 0 )); then
    vf_preserve_evidence
  else
    rm -rf "$work_dir"
  fi
  exit "$rc"
}
trap on_exit EXIT

on_signal() {
  echo "Denial probe interrupted by a signal; the temporary root will be preserved as evidence." >&2
  exit 130
}
trap on_signal INT TERM

cat > "$work_dir/main.tf" <<'EOF'
terraform {
  required_version = ">= 1.12.0, < 2.0.0"
  backend "oci" {}
}
EOF

cat > "$work_dir/backend.hcl" <<EOF
bucket    = "$VALIDATION_LIB_APPROVED_BUCKET"
namespace = "$VALIDATION_LIB_APPROVED_NAMESPACE"
key       = "$VALIDATION_STATE_KEY"
region    = "$VALIDATION_LIB_APPROVED_REGION"
EOF
case "$VALIDATION_AUTH_MODE" in
  APIKey)
    {
      echo 'auth                = "APIKey"'
      echo "config_file_profile = \"$VALIDATION_PROFILE\""
    } >> "$work_dir/backend.hcl"
    ;;
  ResourcePrincipal)
    echo 'auth                = "ResourcePrincipal"' >> "$work_dir/backend.hcl"
    ;;
esac

# Record whether the probe key exists before initialization; the post-check
# proves the probe wrote nothing either way.
existed_before=false
if oci "${VALIDATION_OCI_ARGS[@]}" os object head \
    --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$VALIDATION_STATE_KEY" >/dev/null 2>&1; then
  existed_before=true
fi

if "$VALIDATION_TERRAFORM" -chdir="$work_dir" init -input=false -backend-config=backend.hcl > "$work_dir/init.log" 2>&1; then
  echo "Expected the underprivileged identity to be denied state-bucket access." >&2
  exit 1
fi

if ! grep -qiE 'denied|not authorized|unauthorized|forbidden|NotAuthenticated|NotAuthorizedOrNotFound' "$work_dir/init.log"; then
  echo "Backend initialization failed for a reason other than an authorization denial." >&2
  sed -n '1,120p' "$work_dir/init.log" >&2
  exit 1
fi

existed_after=false
if oci "${VALIDATION_OCI_ARGS[@]}" os object head \
    --bucket-name "$VALIDATION_LIB_APPROVED_BUCKET" --name "$VALIDATION_STATE_KEY" >/dev/null 2>&1; then
  existed_after=true
fi
if [[ "$existed_before" != "$existed_after" ]]; then
  echo "The probe reported a denial but the state key's presence changed; treat the identity as privileged and stop for review." >&2
  exit 1
fi

echo "Underprivileged identity was denied access to the disposable Terraform state key; no object was written."
echo "Validation state key probed (unchanged): $VALIDATION_STATE_KEY"
