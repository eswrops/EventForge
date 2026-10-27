#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$repo_root/tests/ci/test-safe-plan.sh"
"$repo_root/tests/ci/test-configure-oci-wif.sh"
"$repo_root/tests/ci/test-oidc-claim-inspection.sh"
"$repo_root/tests/ci/test-bootstrap-policy.sh"
"$repo_root/tests/ci/test-oci-backend-config.sh"
"$repo_root/tests/ci/test-oci-live-validation-guards.sh"
"$repo_root/tests/ci/test-required-checks.sh"
"$repo_root/tests/release/test-install-release.sh"
"$repo_root/tests/acceptance/test-runner.sh"
