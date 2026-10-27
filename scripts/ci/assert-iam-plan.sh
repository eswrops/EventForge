#!/usr/bin/env bash
set -euo pipefail

# IAM execution guard — exact-plan checker for the corrective MySQL
# resource-principal policies (docs/acceptance/m1-local/
# approvals/mysql-nsg-iam-approval.template). Fails closed against any plan
# that is not EXACTLY the reviewed two-policy create set:
#   - the only non-no-op resource changes allowed are the two contract
#     addresses, each with actions exactly ["create"];
#   - name, compartment_id and the complete statements array must equal the
#     contract values rendered with the operator OCIDs (--var);
#   - any additional changed resource, any update/delete/replacement, and any
#     statement differing by one character is refused.
# Contract and renderer are shared with scripts/local/m1-iam-apply.sh, which
# uses --print-statements to verify the written approval record verbatim.

usage() {
  echo "usage: assert-iam-plan.sh --policy <iam-plan-contract.json> [--var k=v ...] <terraform-plan-json>" >&2
  echo "       assert-iam-plan.sh --policy <iam-plan-contract.json> --var k=v ... --print-statements" >&2
  exit 64
}

policy=""
plan=""
print_statements=0
vars=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy) policy="$2"; shift 2 ;;
    --var) vars+=("$2"); shift 2 ;;
    --print-statements) print_statements=1; shift ;;
    *) plan="$1"; shift ;;
  esac
done
[[ -n "$policy" ]] || usage
[[ -f "$policy" ]] || { echo "IAM plan contract missing: $policy" >&2; exit 64; }
if ((print_statements == 0)); then
  [[ -n "$plan" ]] || usage
fi

# Render a contract template string: substitute ${key} placeholders with the
# --var values (see the rendered-contract block below; the helper exists for
# callers that need single-string rendering).


[[ ${#vars[@]} -gt 0 ]] || { echo "at least one --var is required" >&2; exit 64; }

# Render the contract's ${...} placeholders with the operator OCIDs into a
# scratch copy (deleted on exit) so every downstream comparison — plan check
# and approval-record verification — uses exactly the reviewed strings.
rendered_contract="$(mktemp "${TMPDIR:-/tmp}/iam-plan-contract.XXXXXX")"
trap 'rm -f "$rendered_contract"' EXIT
rendered="$(cat "$policy")"
for kv in "${vars[@]}"; do
  k="${kv%%=*}" v="${kv#*=}"
  [[ -n "$v" ]] || { echo "empty --var value for $k" >&2; exit 64; }
  rendered="${rendered//\$\{$k\}/$v}"
done
# shellcheck disable=SC2016  # intentional literal ${ placeholder probe
if [[ "$rendered" == *'${'* ]]; then
  echo "unresolved placeholder remains in the rendered IAM contract" >&2
  exit 64
fi
printf '%s' "$rendered" > "$rendered_contract"

if ((print_statements == 1)); then
  jq -r '.resources[].statements[]' "$rendered_contract"
  exit 0
fi

# Same structural validation of the plan document as the general checker.
if ! jq -e '
  def valid_actions:
    type == "array" and length > 0 and
    all(.[]; type == "string" and (. as $action | ["no-op", "create", "update", "delete", "read"] | index($action) != null)) and
    ((index("no-op") == null) or . == ["no-op"]);
  type == "object" and (.resource_changes | type == "array") and
  all(.resource_changes[];
    type == "object" and (.address | type == "string" and length > 0) and
    (.type | type == "string" and length > 0) and (.change | type == "object") and
    (.change.actions | valid_actions) and
    (.change | has("after")) and (.change.after == null or (.change.after | type == "object")) and
    ((.change.after_unknown? // {}) | type == "object")
  )
' "$plan" >/dev/null; then
  echo "Terraform plan JSON is invalid or incomplete." >&2
  exit 64
fi

if ! jq -e '
  type == "object" and (.resources | type == "array") and (.resources | length > 0) and
  all(.resources[];
    type == "object" and
    (.address | type == "string" and length > 0) and
    (.type | type == "string" and length > 0) and
    (.name | type == "string" and length > 0) and
    (.compartment | type == "string" and length > 0) and
    (.statements | type == "array") and (all(.statements[]; type == "string" and length > 0))
  )
' "$policy" >/dev/null; then
  echo "IAM plan contract is invalid." >&2
  exit 64
fi

# Render the contract to concrete values and evaluate the plan against it.
# jq reads the rendered resources from a rendered-contract temp file; the
# caller's environment provides it (VARS as KEY=VALUE pairs) so the substitution
# stays reviewable in bash above.
violations="$(jq -r --slurpfile contract "$rendered_contract" '
  [.resource_changes[] | select(.change.actions != ["no-op"])] as $changed |
  [ $changed[]
    | . as $c
    | ([$contract[0].resources[] | select(.address == $c.address)]) as $matches
    | if ($matches | length) == 0 then
        "unapproved-change\t\($c.address)\t\($c.change.actions | join(","))"
      elif ($c.change.actions != ["create"]) then
        "not-a-pure-create\t\($c.address)\t\($c.change.actions | join(","))"
      else
        ($matches[0]) as $r |
        if ($c.type != $r.type) then "type-mismatch\t\($c.address)\t\($c.type) != \($r.type)"
        elif ($c.change.after.name != $r.name) then "policy-name-mismatch\t\($c.address)\t\($c.change.after.name // "<absent>")"
        elif ($c.change.after.compartment_id != $r.compartment) then "compartment-mismatch\t\($c.address)\t\($c.change.after.compartment_id // "<absent>")"
        elif ($c.change.after.statements != $r.statements) then "statement-mismatch\t\($c.address)\t-reviewed-vs-plan-"
        else empty end
      end
  ]
  +
  ([ $contract[0].resources[] | .address as $a |
     select(([$changed[] | select(.address == $a)] | length) == 0) |
     "reviewed-change-missing\t\($a)\t-none-" ])
| .[]
' "$plan")"

if [[ -n "$violations" ]]; then
  echo "Refusing plan under the IAM execution contract:" >&2
  while IFS=$'\t' read -r reason address detail; do
    printf '%s: %s (%s)\n' "$reason" "$address" "$detail" >&2
  done <<<"$violations"
  exit 1
fi

echo "Terraform plan matches the reviewed IAM two-policy contract exactly."
