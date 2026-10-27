#!/usr/bin/env bash
set -euo pipefail

# Offline dry-run tests for ops/scripts/eventforge-install-release. No real
# network, no systemd, no port binding: curl and systemctl are PATH stubs and
# the release root is redirected into a temp directory via the script's
# documented test seams (EVENTFORGE_RELEASE_ROOT, EVENTFORGE_READYZ_POLLS,
# EVENTFORGE_POLL_INTERVAL). Production defaults are unchanged.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="$repo_root/ops/scripts/eventforge-install-release"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub_dir="$tmp/stubs"
readyz_fails_file="$tmp/readyz-fails"

mkdir -p "$stub_dir"

fail() { echo "FAIL: $1" >&2; exit 1; }

# systemctl stub: records every invocation, always succeeds.
cat > "$stub_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
EOF

# curl stub: serves the fixture release metadata and assets, records auth
# headers, honors --output, and implements a scripted /readyz (a
# remaining-failure counter).
cat > "$stub_dir/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
outfile=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-H" && -n "${CURL_HEADER_LOG:-}" ]]; then
    printf '%s\n' "$a" >> "$CURL_HEADER_LOG"
  fi
  if [[ "$prev" == "-o" || "$prev" == "--output" ]]; then
    outfile="$a"
  fi
  prev="$a"
done
case "$args" in
  *"api.github.com/"*)
    cat "${RELEASE_JSON:?}"
    exit 0
    ;;
  *"/readyz"*)
    if [[ -s "${READYZ_FAILS:?}" ]]; then
      n="$(cat "$READYZ_FAILS")"
      if [[ "$n" -gt 0 ]]; then
        printf '%s' "$((n - 1))" > "$READYZ_FAILS"
        exit 7
      fi
    fi
    exit 0
    ;;
  *)
    name="${args##*/}"
    if [[ -n "$outfile" ]]; then
      cat "${ASSET_DIR:?}/$name" > "$outfile"
    else
      cat "${ASSET_DIR:?}/$name"
    fi
    exit 0
    ;;
esac
EOF
chmod +x "$stub_dir/systemctl" "$stub_dir/curl"

# checksum command available on this host (same preference the installer uses)
if command -v sha256sum >/dev/null 2>&1; then
  checksum() { sha256sum "$@"; }
else
  checksum() { shasum -a 256 "$@"; }
fi

tag_counter=0
# Sets the global $tag (a $(new_tag) subshell would lose the counter increment).
new_tag() {
  tag_counter=$((tag_counter + 1))
  tag="v0.${tag_counter}.0-test"
}

# Build a fixture release (two binaries + correct SHA256SUMS) and the matching
# stub release JSON. Extra args are appended verbatim to SHA256SUMS.
make_release() {
  local tag="$1" worker_bytes="${2:-worker-payload}" sums_extra="${3:-}"
  asset_dir="$tmp/assets-$tag"
  mkdir -p "$asset_dir"
  printf 'api-payload-%s' "$tag" > "$asset_dir/eventforge-api-$tag"
  printf '%s' "$worker_bytes" > "$asset_dir/eventforge-worker-$tag"
  (cd "$asset_dir" && checksum "eventforge-api-$tag" "eventforge-worker-$tag") > "$asset_dir/SHA256SUMS"
  if [[ -n "$sums_extra" ]]; then
    printf '%s\n' "$sums_extra" >> "$asset_dir/SHA256SUMS"
  fi
  release_json="$tmp/release-$tag.json"
  {
    printf '{"assets":['
    sep=""
    for asset in "eventforge-api-$tag" "eventforge-worker-$tag" "SHA256SUMS"; do
      printf '%s{"name":"%s","browser_download_url":"https://assets.invalid/%s"}' "$sep" "$asset" "$asset"
      sep=","
    done
    printf ']}\n'
  } > "$release_json"
}

run_install() {
  local tag="$1"
  shift
  env \
    PATH="$stub_dir:$PATH" \
    GITHUB_REPOSITORY="owner/EventForge" \
    "$@" \
    SYSTEMCTL_LOG="$systemctl_log" \
    CURL_LOG="$curl_log" \
    CURL_HEADER_LOG="$curl_header_log" \
    EVENTFORGE_RELEASE_ROOT="$root" \
    EVENTFORGE_POLL_INTERVAL="${EVENTFORGE_POLL_INTERVAL:-0}" \
    READYZ_FAILS="$readyz_fails_file" \
    RELEASE_JSON="$release_json" \
    ASSET_DIR="$asset_dir" \
    "$installer" "$tag" > "$out" 2>&1
}

scenario_root() {
  root="$tmp/opt-$1"
  systemctl_log="$tmp/systemctl-$1.log"
  curl_log="$tmp/curl-$1.log"
  curl_header_log="$tmp/headers-$1.log"
  out="$tmp/out-$1.txt"
  : > "$curl_header_log"
  : > "$readyz_fails_file"
}

link_target() { readlink -f "$root/current"; }

# 1. Happy path: install, verify, atomic switch, api restart, readyz, worker.
scenario_root happy
new_tag
make_release "$tag"
if ! run_install "$tag" GITHUB_TOKEN=""; then
  cat "$out" >&2; fail "happy path install exited non-zero"
fi
grep -q "installed successfully" "$out" || fail "happy path success message missing"
[[ -L "$root/current" ]] || fail "current is not a symlink"
[[ "$(link_target)" == "$(readlink -f "$root/releases/$tag")" ]] || fail "current does not point at the new release"
grep -q "restart eventforge-api.service" "$systemctl_log" || fail "api restart missing"
grep -q "restart eventforge-worker.service" "$systemctl_log" || fail "worker restart missing"
grep -q "restart eventforge-api.service eventforge-worker.service" "$systemctl_log" \
  && fail "rollback restart ran on the happy path"
leftover=0
for entry in "$root"/.incoming.* "$root"/current.incoming.*; do
  [[ -e "$entry" ]] && leftover=1
done
[[ "$leftover" -eq 0 ]] || fail "leftover incoming symlink"

# 2. Second install switches again and retains the previous release.
old_tag="$tag"
new_tag
make_release "$tag"
if ! run_install "$tag" GITHUB_TOKEN=""; then
  cat "$out" >&2; fail "second install exited non-zero"
fi
[[ "$(link_target)" == "$(readlink -f "$root/releases/$tag")" ]] || fail "switch to second release failed"
[[ -d "$root/releases/$old_tag" ]] || fail "previous release not retained"
[[ -f "$root/releases/$old_tag/eventforge-api-$old_tag" ]] || fail "previous release artifacts missing"

# 3. Tampered binary rejects the release (bad checksum).
scenario_root badsum
new_tag
make_release "$tag"
printf 'x' >> "$asset_dir/eventforge-worker-$tag" # served bytes no longer match SHA256SUMS
if run_install "$tag" GITHUB_TOKEN=""; then
  fail "tampered worker was installed"
fi
grep -qi "checksum\|SHA" "$out" || fail "checksum failure not reported"
[[ ! -e "$root/current" ]] || fail "current changed despite failed verification"
[[ ! -d "$root/releases/$tag" ]] || fail "partial release dir not cleaned up"
[[ ! -s "$systemctl_log" ]] || fail "services restarted despite failed verification"

# 4. Missing asset rejects the release.
scenario_root noasset
new_tag
make_release "$tag"
release_json="$tmp/release-$tag-noasset.json"
printf '{"assets":[{"name":"eventforge-api-%s","browser_download_url":"https://assets.invalid/eventforge-api-%s"}]}\n' "$tag" "$tag" > "$release_json"
if run_install "$tag" GITHUB_TOKEN=""; then
  fail "install succeeded despite missing worker asset"
fi
[[ ! -e "$root/current" ]] || fail "current changed despite missing asset"
[[ ! -d "$root/releases/$tag" ]] || fail "partial release dir not cleaned up (missing asset)"

# 5. Malformed manifest rejects the release.
scenario_root badmanifest
new_tag
make_release "$tag" "" "this-is-not-a-checksum-line"
if run_install "$tag" GITHUB_TOKEN=""; then
  fail "install succeeded with a malformed manifest"
fi
[[ ! -e "$root/current" ]] || fail "current changed despite malformed manifest"

# 6. Manifest without entries for the downloaded binaries must reject
#    (regression: --ignore-missing would otherwise pass vacuously).
scenario_root sparsemanifest
new_tag
make_release "$tag"
sed 's/"SHA256SUMS"/"SHA256SUMS-api-only"/' "$release_json" > "$release_json-sparse"
grep "eventforge-api-" "$asset_dir/SHA256SUMS" > "$asset_dir/SHA256SUMS-api-only"
release_json="$release_json-sparse"
if run_install "$tag" GITHUB_TOKEN=""; then
  fail "vacuous manifest verification passed"
fi
[[ ! -e "$root/current" ]] || fail "current changed despite sparse manifest"

# 7. Health-check failure after the switch rolls back to the previous release.
scenario_root rollback
new_tag
base_tag="$tag"
make_release "$base_tag"
if ! run_install "$base_tag" GITHUB_TOKEN=""; then
  cat "$out" >&2; fail "base release install failed"
fi
base_link_target="$(link_target)"
new_tag
fail_tag="$tag"
make_release "$fail_tag"
printf '99' > "$readyz_fails_file"
if run_install "$fail_tag" EVENTFORGE_READYZ_POLLS=2 GITHUB_TOKEN=""; then
  fail "install succeeded although readyz never passed"
fi
grep -q "API never became ready" "$out" || fail "readiness exhaustion not reported"
grep -q "restored previous release" "$out" || fail "rollback message missing"
[[ "$(link_target)" == "$(readlink -f "$base_link_target")" ]] || fail "current was not restored to the previous release"
grep -q "restart eventforge-api.service eventforge-worker.service" "$systemctl_log" \
  || fail "rollback service restart missing"

# 8. Health-check failure with no previous release restores nothing but fails.
scenario_root noprevious
new_tag
make_release "$tag"
printf '99' > "$readyz_fails_file"
if run_install "$tag" EVENTFORGE_READYZ_POLLS=2 GITHUB_TOKEN=""; then
  fail "install succeeded although readyz never passed (no previous)"
fi
grep -q "no previous release to restore" "$out" || fail "honest no-rollback message missing"
[[ "$(link_target)" == "$(readlink -f "$root/releases/$tag")" ]] || fail "current should keep the only installed release"

# 9. Secrets never appear in the installer's own output.
scenario_root secrets
new_tag
make_release "$tag"
token="SUPERSECRET-TOKEN-VALUE"
if ! run_install "$tag" GITHUB_TOKEN="$token"; then
  cat "$out" >&2; fail "authenticated install failed"
fi
if grep -q "$token" "$out" "$systemctl_log"; then
  fail "GITHUB_TOKEN leaked into installer output or service log"
fi
grep -q "Authorization: Bearer $token" "$curl_header_log" || fail "auth header not sent to the API"

# 10. Without a token no Authorization header is sent (public release assets).
scenario_root notoken
new_tag
make_release "$tag"
if ! run_install "$tag" GITHUB_TOKEN=""; then
  cat "$out" >&2; fail "unauthenticated install failed"
fi
[[ ! -s "$curl_header_log" ]] || fail "Authorization header sent without a token"

# 11. Re-installing the same immutable tag is rejected.
scenario_root idempotent
new_tag
make_release "$tag"
if ! run_install "$tag" GITHUB_TOKEN=""; then
  fail "first install failed"
fi
if run_install "$tag" GITHUB_TOKEN=""; then
  fail "duplicate install of the same tag succeeded"
fi
grep -q "already exists" "$out" || fail "duplicate install message missing"

# 12. The switch must be rename-based (atomicity contract) — documentation
#     guard against regressing to plain unlink+recreate.
grep -q "switch_current_symlink" "$installer" || fail "atomic switch helper missing"
grep -q "mv -Tf" "$installer" || fail "rename-based switch missing"

echo "release installer dry-run tests passed (12 scenarios)"
