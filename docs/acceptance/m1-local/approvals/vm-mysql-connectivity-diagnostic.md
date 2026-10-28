# VM→MySQL CONNECTIVITY DIAGNOSTIC — prepared, NOT executed (Run Command path)

GATE: VM-CONNECTIVITY-DIAGNOSTIC
APPROVER: <operator name>

> Prepared 2026-10-28; finalized by the minimal-privilege IAM package mission
> and its review corrections (implementation in the UNMERGED PR
> `prepare/b5-run-command-iam`). Direct SSH from the workstation is blocked
> because its public IP rotated (`49.207.214.221` → `49.207.216.108`) and the
> reviewed SSH sources are `/32`-locked; updating them is a network change
> this package does NOT request. The remaining read-only diagnostic path is
> OCI **Compute Run Command** on the two existing VMs. THREE INDEPENDENT
> approvals are required for this path (A, B, C below) — none implies
> another, and none is implied by the MYSQL-NSG-IAM or MYSQL-NSG-RETEST
> records.

## Readiness findings (2026-10-28, all read-only)

1. **Plugin status (actual runtime, via `oci instance-agent plugin list`):**
   `Compute Instance Run Command: RUNNING` on BOTH
   `rust-api-test` and `rust-api-worker`.
2. **Operator command-creation permission: PRESENT** — the Tenant Admin
   policy `ALLOW GROUP Administrators to manage all-resources IN TENANCY`
   covers command creation/management for the operator principal (the
   successful read-only `instance-agent command list` probe demonstrates the
   read verb; creation is granted by the same policy family — LIST success
   alone is NOT treated as proof of CREATE).
3. **Instance execution permission: MISSING** — the tenancy's dynamic group
   `eventforge-instances`
   (`ocid1.dynamicgroup.oc1..aaaaaaaai7mkqwxjumgmvnibatrbwdn2ohnih2oxc4s3slc5on4riyazdvwa`)
   already matches EXACTLY the two VM OCIDs, but its only policy
   (`eventforge-instance-backups`) grants backup-bucket object storage.
   Closing the gap requires approval A below.

## The pinned diagnostic script (465 bytes — well inside the 4 KB plaintext
content limit; output ≈150 bytes — well inside the last-1 KB output bound
Oracle's Run Command service retains)

SHA-256: `ddd3b3ac66039e6d991513a317010dbcb2610edb6aff3557f2ad43fd4219d08d`
(copy preserved outside Git at
`/Users/eswr/secure/evidence/b5prep-diagnostics/vm-mysql-connectivity-check.sh`)

```bash
set -u
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VM=$(hostname)
IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.0\.2\.' | head -1)
echo "VM=$VM IP=$IP TS=$TS"
if OUT=$(timeout 5 bash -c 'exec 3<>/dev/tcp/10.0.3.18/3306 && head -c 60 <&3' 2>&1); then
  echo "TCP-3306: CONNECT OK"
  echo "MYSQL-GREETING: $(printf '%s' "$OUT" | tr -d '\0' | tr -c '[:print:]\n' '.')"
  RC=0
else
  RC=$?
  echo "TCP-3306: FAIL rc=$RC detail=$OUT"
fi
echo "DIAG-EXIT: $RC"
exit "$RC"
```

Compliance: target exactly `10.0.3.18:3306`; no credentials (pre-auth server
handshake only); no `sudo` invocation (the Run Command agent executes as
root — disclosed platform behavior, not a script choice); no filesystem
modifications (no temp files; shell-variable capture only); no services
restarted; bounded by `timeout 5` in-script plus a 60-second
`--execution-timeout`; VM identity + UTC timestamp recorded; TCP result,
greeting result, explicit `DIAG-EXIT` code; execution status read back via
`oci instance-agent command-execution get` (SUCCESS/FAILED + exit code).

## Approval A — one-policy IAM creation (independent; unmerged PR)

GATE: IAM-RUN-COMMAND-DIAG
APPROVAL_DECISION: <OPERATOR_AUTHORIZATION_REQUIRED>
APPROVER: <operator name>
Grant phrase: <verbatim operator grant>
Timestamp (UTC): <YYYY-MM-DDTHH:MM:SSZ>
Saved-plan SHA-256: <sha256 of the exists-mode diagnostics plan>
Source commit: <full merged main commit>
Policy address: oci_identity_policy.instance_run_command_diagnostics
Statement: Allow dynamic-group eventforge-instances to use instance-agent-command-execution-family in compartment id ocid1.compartment.oc1..aaaaaaaar3kvayxcj4vuo6ydkoaxrh4yeovnvr6rgxr7kdljzijrpbxaz3ea where request.instance.id=target.instance.id
IAM state lineage/serial at plan time: <lineage>/<serial>

Exactly one new IAM policy, prepared as
`oci_identity_policy.instance_run_command_diagnostics` on the existing
`infra/iam` root (dedicated contract
`scripts/ci/iam-plan-contract-diag.json`: exactly one CREATE, the two
reviewed MySQL policies untouched, `prevent_destroy` carried, plan generated
in exists-mode via `M1_IAM_EXPECT_STATE=exists M1_IAM_PLAN_CONTRACT=scripts/ci/iam-plan-contract-diag.json scripts/local/m1-iam-plan.sh`,
applied once via `scripts/local/m1-iam-diag-apply.sh`):

```
Allow dynamic-group eventforge-instances to use instance-agent-command-execution-family in compartment id ocid1.compartment.oc1..aaaaaaaar3kvayxcj4vuo6ydkoaxrh4yeovnvr6rgxr7kdljzijrpbxaz3ea where request.instance.id=target.instance.id
```

**Oracle-standard form.** Oracle's Run Command example explicitly documents
this combination — `use instance-agent-command-execution-family` granted to
the instances' dynamic group with the
`where request.instance.id=target.instance.id` condition. This is the
documented standard, and it is also the least-privilege reading: `use` grants
READ on the execution family (the arbitrary-code trigger
`INSTANCE_AGENT_COMMAND_EXECUTION_CREATE` exists only at `manage`, which
stays operator-side), the compartment is Test only, and the dynamic group
matches exactly the two VM OCIDs.

**Operational caveat (retained):** creating the policy does NOT prove
command completion. The first approved command execution must be verified
end-to-end (`oci instance-agent command-execution get` reaching SUCCESS with
output). If commands are created but never polled or completed, STOP and
prepare a re-reviewed package — never broaden in place.

The existing backup policy and both applied MySQL policies are untouched.
Permanence: this policy exists only for the connectivity diagnostics; it
SHOULD be removed after the post-retest diagnostic window via a separate
destroy-approving package.

Machine gate (`scripts/local/m1-iam-diag-apply.sh`): the unchanged template
refuses execution; `m1_verify_approval_decision` requires EXACTLY ONE
standalone `APPROVAL_DECISION: AUTHORIZE_ONE_DIAGNOSTIC_IAM_CREATE` line;
the APPROVER / Grant phrase / Timestamp fields must be operator-entered
(fill markers refuse); the plan SHA-256, commit, policy address, rendered
statement, and the plan-time IAM state lineage/serial are all verified
before any live access; a consumed (`applied=true`) plan refuses. Approval
fields are never inserted automatically; the grant must be separately
attributable to the operator.

## Approval B — two pre-retest diagnostic executions (independent)

GATE: VM-CONNECTIVITY-DIAGNOSTIC
APPROVER: <operator name>

Exactly two executions of the pinned script (one per VM: `rust-api-test`
10.0.2.129, `rust-api-worker` 10.0.2.94) BEFORE any MySQL change, producing
CURRENT connectivity evidence for retest precondition 4. A failure on a VM
is itself diagnostic and pauses the retest authorization for reassessment.

## Approval C — two post-retest diagnostic executions (independent)

GATE: VM-CONNECTIVITY-DIAGNOSTIC-POST-RETEST
APPROVER: <operator name>

Exactly two executions of the identical pinned script (SHA-256
`ddd3b3ac…`) AFTER the MYSQL-NSG-RETEST work request reaches SUCCEEDED and
live membership is confirmed — proving the new app-NSG↔db-NSG path carries
3306 (the pairing is ADDITIVE to the retained SL rule, so connectivity must
hold). This is the evidence the later SL-CORRECTION package builds on.

## Out of scope

No SSH-source update, no console/credential change, no reboot, no agent
plugin reconfiguration, no IAM change beyond approval A's single policy, no
MySQL change, no security-list change, and no MYSQL-NSG-RETEST
authorization (that remains the separate, later record).

Dated statement: I authorize the approvals marked above (A / B / C — initial
each), exactly as described, nothing else.
Date: <YYYY-MM-DD>
