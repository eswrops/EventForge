#!/usr/bin/env bash
set -euo pipefail

# Scope-A safe-plan checker: attribute-level authorization for the reviewed
# NSG-association change set (docs/acceptance/m1-local/
# scope-a-network-execution-approval.md). Runs IN ADDITION to the general
# assert-safe-plan.sh with the scope-A policy — an address-level permission
# alone is insufficient here:
#   - exactly the four reviewed addresses may change, each with actions
#     exactly ["update"] (replacement/deletion is refused outright);
#   - the before/after JSON is compared at attribute level: the only permitted
#     changed leaf paths are the policy's allowed_attribute_paths, the after
#     values must equal the reviewed NSG OCIDs exactly, and the before values
#     must equal the reviewed prior memberships (append-only guarantee);
#   - any unknown (after_unknown=true) attribute on a changed resource is
#     refused — an unknown exposure-relevant value must never be resolved
#     by an apply;
#   - every reviewed allow entry must match exactly one changed address, so a
#     plan that silently drops one of the four changes is also refused.
# The general M1-LOCAL policy is not weakened by this script: it operates on a
# separate scope-A policy and is never used for M1-LOCAL applies.

if [[ $# -ne 3 || "$1" != "--policy" ]]; then
  echo "usage: assert-safe-plan-scope-a.sh --policy <scope-a-policy.json> <terraform-plan-json>" >&2
  exit 64
fi

policy="$2"
plan="$3"

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
  def valid_regex: type == "string" and length > 0 and (try test("") catch false);
  def valid_map: type == "object" and all(to_entries[]; .key | type == "string");
  type == "object" and (.allow | type == "array") and (.protected_imports | type == "array") and
  all(.protected_imports[]; valid_regex) and
  all(.allow[];
    type == "object" and (.address_regex | valid_regex) and
    (.actions == ["update"]) and (.allow_import_update == true) and
    (.allowed_attribute_paths | type == "array") and (all(.allowed_attribute_paths[]; type == "string" and length > 0)) and
    (.expected_attribute_values | valid_map) and (.expected_attribute_values_before | valid_map)
  )
' "$policy" >/dev/null; then
  echo "Scope-A safe-plan policy is invalid." >&2
  exit 64
fi

violations="$(jq -r --slurpfile policy "$policy" '
  def matching_rules($address): [$policy[0].allow[] | select(.address_regex as $pattern | ($address | test($pattern)))];
  def leaf_diff($a; $b; $path):
    if ($a | type) == "array" and ($b | type) == "array" and ($a | length) == 1 and ($b | length) == 1
       and (($a[0] | type) == "object") and (($b[0] | type) == "object") then
      leaf_diff($a[0]; $b[0]; $path)
    elif ($a | type) == "object" and ($b | type) == "object" then
      ([ $a | keys[] as $k | leaf_diff($a[$k]; (if $b | has($k) then $b[$k] else "__ABSENT__" end); ($path + [$k])) ]
       | flatten) +
      ([ $b | keys[] as $k | select(($a | has($k)) | not) | leaf_diff("__ABSENT__"; $b[$k]; ($path + [$k])) ]
       | flatten)
    else
      (if $a != $b then [{ p: ($path | join(".")), before: $a, after: $b }] else [] end)
    end;
  def unknown_leaves($o; $path):
    if ($o | type) == "object" or ($o | type) == "array" then
      ([ $o | to_entries[] | unknown_leaves(.value; ($path + [.key | tostring])) ] | flatten)
    elif $o == true then
      [{ p: ($path | join(".")) }]
    else [] end;
  [.resource_changes[] | select(.change.actions != ["no-op"])] as $changed |
  ([ $changed[] | . as $c |
     (matching_rules($c.address)) as $matches |
     if ($matches | length) == 0 then "unapproved-change\t\($c.address)\t\($c.change.actions | join(","))"
     elif ($matches | length) > 1 then "ambiguous-policy-match\t\($c.address)\t\($c.change.actions | join(","))"
     elif ($c.change.actions != ["update"]) then "not-a-pure-update\t\($c.address)\t\($c.change.actions | join(","))"
     else
       ($matches[0]) as $rule |
       ([ leaf_diff($c.change.before; $c.change.after; [])[] ] | map(select(.p != "__ABSENT__"))) as $diffs |
       ([ $diffs[].p ]) as $diff_paths |
       ([ unknown_leaves($c.change.after_unknown; [])[] | .p ]) as $unknown_paths |
       ([ $diffs[] | select(.before == "__ABSENT__" or .after == "__ABSENT__") | .p ]) as $absent_paths |
       ([ $diff_paths[] | select(. as $p | $rule.allowed_attribute_paths | index($p) | not) ]) as $forbidden_paths |
       ([ $rule.allowed_attribute_paths[] as $p
          | select(($rule.expected_attribute_values[$p] // "__MISSING__")
                   != ($diffs | map(select(.p == $p)) | .[0].after // "__MISSING__")) ]) as $value_mismatches |
       ([ $rule.allowed_attribute_paths[] as $p
          | select(($rule.expected_attribute_values_before[$p] // "__MISSING__")
                   != ($diffs | map(select(.p == $p)) | .[0].before // "__MISSING__")) ]) as $before_mismatches |
       if ($unknown_paths | length) > 0 then "unknown-attribute\t\($c.address)\t\($unknown_paths | join(","))"
       elif ($absent_paths | length) > 0 then "attribute-added-or-removed\t\($c.address)\t\($absent_paths | join(","))"
       elif ($forbidden_paths | length) > 0 then "non-nsg-attribute-change\t\($c.address)\t\($forbidden_paths | join(","))"
       elif ($value_mismatches | length) > 0 then "unexpected-attribute-value\t\($c.address)\t\($value_mismatches | join(","))"
       elif ($before_mismatches | length) > 0 then "unexpected-prior-membership\t\($c.address)\t\($before_mismatches | join(","))"
       else empty end
     end ]
   +
   ([ $policy[0].allow[] | .address_regex as $pattern |
      select(([$changed[] | select(.address | test($pattern))] | length) == 0) |
      "reviewed-change-missing\t\($pattern)\t-none-" ])
| .[]
)' "$plan")"

if [[ -n "$violations" ]]; then
  echo "Refusing plan under the Scope-A policy:" >&2
  while IFS=$'\t' read -r reason address detail; do
    printf '%s: %s (%s)\n' "$reason" "$address" "$detail" >&2
  done <<<"$violations"
  exit 1
fi

echo "Terraform plan matches the Scope-A reviewed NSG-association change set exactly."
