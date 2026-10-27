#!/usr/bin/env bash
set -euo pipefail

# Offline fixtures for scripts/ops/eventforge-sl-update (Scope-A security-list
# corrections). No OCI call is made: the stub OCI binary returns fixture
# responses, and the tests assert that
#   - a manifest whose recorded rule-array hashes match the live object
#     verifies cleanly (and yields the fresh ETag for --if-match),
#   - ANY difference in the live rule arrays (an unexpected concurrent
#     security-list change) causes an abort before any update,
#   - a manifest already at the proposed state reports convergence,
#   - the GET-format rule arrays convert deterministically to the camelCase
#     form the CLI update call requires.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/scripts/ops/eventforge-sl-update"
fixtures="$(mktemp -d)"
stubdir="$(mktemp -d)"
trap 'rm -rf "$fixtures" "$stubdir"' EXIT

LB_OCID="ocid1.securitylist.oc1.ap-hyderabad-1.aaaaaaaaelahefjk6ddczauhmu4tznf6pocrtkb7h26ihs2i4nlafoibdsya"

# Fixture: a live LB security-list GET response (two 0.0.0.0/0 ingress rules).
cat > "$fixtures/live-lb.json" <<'EOF'
{"data": {"id": "ocid1.securitylist.oc1.ap-hyderabad-1.aaaaaaaaelahefjk6ddczauhmu4tznf6pocrtkb7h26ihs2i4nlafoibdsya",
  "display-name": "rust-api-lb-public",
  "ingress-security-rules": [
    {"protocol": "6", "source": "0.0.0.0/0", "source-type": "CIDR_BLOCK", "is-stateless": false,
     "tcp-options": {"destination-port-range": {"min": 80, "max": 80}, "source-port-range": null}},
    {"protocol": "6", "source": "0.0.0.0/0", "source-type": "CIDR_BLOCK", "is-stateless": false,
     "tcp-options": {"destination-port-range": {"min": 443, "max": 443}, "source-port-range": null}}
  ],
  "egress-security-rules": [
    {"protocol": "all", "destination": "0.0.0.0/0", "destination-type": "CIDR_BLOCK", "is-stateless": false}
  ]},
 "etag": "etag-live-1"}
EOF

live_ih="$(jq -S -c '."data"."ingress-security-rules"' "$fixtures/live-lb.json" | shasum -a 256 | awk '{print $1}')"
live_eh="$(jq -S -c '."data"."egress-security-rules"' "$fixtures/live-lb.json" | shasum -a 256 | awk '{print $1}')"

make_manifest() { # make_manifest <out> <ingress_hash> <egress_hash>
  jq -n --arg ih "$2" --arg eh "$3" --arg id "$LB_OCID" '{
    security_list_id: $id, display_name: "rust-api-lb-public",
    recorded: {etag: "etag-recorded", ingress_hash: $ih, egress_hash: $eh},
    proposed: {ingress: [], egress: [{"protocol": "all", "destination": "0.0.0.0/0", "destination-type": "CIDR_BLOCK", "is-stateless": false}]}
  }' > "$1"
}

# Stub OCI: `get` returns the fixture, `update` would be a mutation and must
# never be reached in these tests.
cat > "$stubdir/oci" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "network security-list" && "\$3" == "get" ]]; then
  cat "$fixtures/live-lb.json"
  exit 0
fi
if [[ "\$1 \$2 \$3" == "network security-list update" ]]; then
  echo "STUB: update must not be invoked by verify" >&2
  exit 99
fi
echo "STUB: unexpected oci invocation: \$*" >&2
exit 99
EOF
chmod +x "$stubdir/oci"
export EVENTFORGE_OCI_BIN="$stubdir/oci"

# 1. Matching hashes verify cleanly and surface the FRESH ETag.
make_manifest "$fixtures/manifest-ok.json" "$live_ih" "$live_eh"
out="$("$guard" verify "$fixtures/manifest-ok.json")"
[[ "$out" == "verify: preconditions hold; fresh ETag etag-live-1" ]] \
  || { echo "unexpected verify output: $out" >&2; exit 1; }

# 2. A concurrent ingress change (hash mismatch) must abort before any update.
make_manifest "$fixtures/manifest-stale.json" "0000000000000000000000000000000000000000000000000000000000000000" "$live_eh"
if "$guard" verify "$fixtures/manifest-stale.json" >/dev/null 2>&1; then
  echo "Expected a concurrent ingress change to abort verify." >&2
  exit 1
fi

# 3. Same for an egress change.
make_manifest "$fixtures/manifest-stale-eg.json" "$live_ih" "0000000000000000000000000000000000000000000000000000000000000000"
if "$guard" verify "$fixtures/manifest-stale-eg.json" >/dev/null 2>&1; then
  echo "Expected a concurrent egress change to abort verify." >&2
  exit 1
fi

# 4. Already-converged state reports convergence instead of mutating.
cat > "$fixtures/live-converged.json" <<'EOF'
{"data": {"id": "x", "display-name": "rust-api-lb-public",
  "ingress-security-rules": [],
  "egress-security-rules": [
    {"protocol": "all", "destination": "0.0.0.0/0", "destination-type": "CIDR_BLOCK", "is-stateless": false}
  ]},
 "etag": "etag-live-2"}
EOF
# 4. Already-converged state reports convergence instead of mutating. The
# manifest's recorded hashes must match the live (converged) object to get
# past the concurrent-change guard; the convergence branch then compares the
# live arrays to the proposal.
jq '."data"."ingress-security-rules" = [] | .etag = "etag-live-2"' "$fixtures/live-lb.json" > "$stubdir/live-converged-response.json"
conv_ih="$(jq -S -c '."data"."ingress-security-rules"' "$stubdir/live-converged-response.json" | shasum -a 256 | awk '{print $1}')"
conv_eh="$(jq -S -c '."data"."egress-security-rules"' "$stubdir/live-converged-response.json" | shasum -a 256 | awk '{print $1}')"
make_manifest "$fixtures/manifest-converged.json" "$conv_ih" "$conv_eh"
cat > "$stubdir/oci" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "network security-list get" ]]; then
  cat "$stubdir/live-converged-response.json"
  exit 0
fi
echo "STUB: update must not be invoked on a converged state" >&2
exit 99
EOF
out="$("$guard" verify "$fixtures/manifest-converged.json")"
[[ "$out" == "verify: already converged, no update needed" ]] \
  || { echo "unexpected convergence output: $out" >&2; exit 1; }

# 5. apply is refused without the operator attestation / a matching written
# approval record naming the manifest's recorded hashes and GATE marker.
unset_stub_update() {
  cat > "$stubdir/oci" <<EOF2
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "network security-list get" ]]; then
  cat "$fixtures/live-lb.json"
  exit 0
fi
echo "STUB: update must not be invoked in approval tests" >&2
exit 99
EOF2
}
unset_stub_update
apply_expect_fail() { # apply_expect_fail <record> <attestation-value or empty>
  if [[ -n "$2" ]]; then
    M1_SCOPE_A_APPROVED_BY="$2" "$guard" apply --approval-record "$1" "$fixtures/manifest-ok.json" >/dev/null 2>&1
  else
    env -u M1_SCOPE_A_APPROVED_BY "$guard" apply --approval-record "$1" "$fixtures/manifest-ok.json" >/dev/null 2>&1
  fi
}
cat > "$fixtures/record-ok.txt" <<EOF
GATE: SL-CORRECTION
APPROVER: Test Operator
RECORDED-INGRESS-HASH: $live_ih
RECORDED-EGRESS-HASH: $live_eh
EOF
cp "$fixtures/record-ok.txt" "$fixtures/record-wrong-gate.txt"
awk '{if ($0 == "GATE: SL-CORRECTION") print "GATE: SOMETHING-ELSE"; else print}' \
  "$fixtures/record-ok.txt" > "$fixtures/record-wrong-gate.txt"
cat > "$fixtures/record-wrong-hashes.txt" <<EOF
GATE: SL-CORRECTION
APPROVER: Test Operator
RECORDED-INGRESS-HASH: 1111111111111111111111111111111111111111111111111111111111111111
RECORDED-EGRESS-HASH: 2222222222222222222222222222222222222222222222222222222222222222
EOF

if apply_expect_fail "" ""; then echo "apply without attestation must fail" >&2; exit 1; fi
if apply_expect_fail "$fixtures/record-ok.txt" "Other Operator"; then echo "mismatching attestation must fail" >&2; exit 1; fi
if apply_expect_fail "$fixtures/record-wrong-gate.txt" "Test Operator"; then echo "wrong GATE marker must fail" >&2; exit 1; fi
if apply_expect_fail "$fixtures/record-wrong-hashes.txt" "Test Operator"; then echo "unrelated manifest hashes must fail" >&2; exit 1; fi
if apply_expect_fail "/nonexistent-record" "Test Operator"; then echo "missing record must fail" >&2; exit 1; fi

# 6. GET-format → CLI camelCase conversion is deterministic.
cat > "$fixtures/rules-get.json" <<'EOF'
[{"description": "SSH for rust-api-test", "protocol": "6", "source": "49.207.214.221/32", "source-type": "CIDR_BLOCK", "is-stateless": false,
  "tcp-options": {"destination-port-range": {"min": 22, "max": 22}, "source-port-range": null},
  "icmp-options": null, "udp-options": null}]
EOF
converted="$(bash -c "source '$guard' >/dev/null 2>&1; rules_get_to_cli '$fixtures/rules-get.json'")"
jq -e '
  .[0].sourceType == "CIDR_BLOCK" and .[0].isStateless == false and
  .[0].tcpOptions.destinationPortRange.min == 22 and .[0].tcpOptions.destinationPortRange.max == 22 and
  .[0].tcpOptions.sourcePortRange == null and .[0].icmpOptions == null
' <<<"$converted" >/dev/null || { echo "unexpected CLI conversion: $converted" >&2; exit 1; }

echo "security-list guard fixtures passed"
