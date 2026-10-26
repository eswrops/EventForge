#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$repo_root/tests/ci/test-safe-plan.sh"
"$repo_root/tests/ci/test-configure-oci-wif.sh"
"$repo_root/tests/ci/test-oidc-claim-inspection.sh"
"$repo_root/tests/acceptance/test-runner.sh"
