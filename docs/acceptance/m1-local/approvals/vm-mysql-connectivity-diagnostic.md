# VM→MySQL CONNECTIVITY DIAGNOSTIC — procedure and readiness (no approvals here)

> Readiness and execution procedure for re-verifying VM→MySQL connectivity
> via OCI Compute Run Command (the workstation's public IP rotated
> `49.207.214.221` → `49.207.216.108`, and the reviewed SSH sources are
> `/32`-locked; no SSH-source change is requested). This document carries NO
> approval gates — every authorization lives in its own dedicated template
> file, and the completed records stay OUTSIDE Git:
>
> | Approval | Template | Scope |
> | --- | --- | --- |
> | A | [iam-run-command-diag-approval.template](iam-run-command-diag-approval.template) | Exactly one `GATE: IAM-RUN-COMMAND-DIAG` — one IAM policy CREATE on `infra/iam` |
> | B | [vm-connectivity-diag-approval.template](vm-connectivity-diag-approval.template) | Exactly one `GATE: VM-CONNECTIVITY-DIAGNOSTIC` — two pre-retest executions |
> | C | [vm-connectivity-diag-post-retest-approval.template](vm-connectivity-diag-post-retest-approval.template) | Exactly one `GATE: VM-CONNECTIVITY-DIAGNOSTIC-POST-RETEST` — two post-retest executions |
>
> A, B, and C are INDEPENDENT: none implies another, and none is implied by
> the MYSQL-NSG-IAM or MYSQL-NSG-RETEST records.

## Readiness findings (2026-10-28, all read-only)

1. **Plugin status (actual runtime, via `oci instance-agent plugin list`):**
   `Compute Instance Run Command: RUNNING` on BOTH
   `rust-api-test` (10.0.2.129 / public 129.225.99.202) and
   `rust-api-worker` (10.0.2.94 / public 129.225.99.0).
2. **Operator command-creation permission: PRESENT** — the Tenant Admin
   policy `ALLOW GROUP Administrators to manage all-resources IN TENANCY`
   covers command creation/management for the operator principal (the
   successful read-only `instance-agent command list` probe demonstrates the
   read verb; creation is granted by the same policy family — LIST success
   alone is NOT treated as proof of CREATE).
3. **Instance execution permission: MISSING** — the dynamic group
   `eventforge-instances`
   (`ocid1.dynamicgroup.oc1..aaaaaaaai7mkqwxjumgmvnibatrbwdn2ohnih2oxc4s3slc5on4riyazdvwa`)
   already matches EXACTLY the two VM OCIDs, but its only policy
   (`eventforge-instance-backups`) grants backup-bucket object storage.
   Approval A closes exactly this gap.

## The pinned diagnostic script (465 bytes — well inside the 4 KB plaintext
content limit; output ≈150 bytes — far inside the last-1 KB output bound
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
handshake only); **no `sudo`** — Run Command's default Linux execution user
is **`ocarun`**, and elevated permissions would require separate guest
configuration, which this procedure does not make and does not need (the
target is an unprivileged TCP connect + read of the server's pre-auth
handshake); no guest configuration mutation; no filesystem modifications
(shell-variable capture only); no services restarted; bounded by `timeout 5`
in-script plus a 60-second `--execution-timeout`; VM identity + UTC
timestamp recorded; TCP result, greeting result, explicit `DIAG-EXIT` code;
execution status read back via `oci instance-agent command-execution get`
(SUCCESS/FAILED + exit code; Oracle retains the last 1 KB of output).

## Execution form (after A and the relevant B/C approval exist)

```bash
oci instance-agent command create \
  --compartment-id <Test> --instance-id <instance OCID> \
  --display-name "b5-connectivity-diag-<vm>" \
  --execution-timeout-in-seconds 60 \
  --content file:///Users/eswr/secure/evidence/b5prep-diagnostics/vm-mysql-connectivity-check.sh
```

Interpretation: `TCP-3306: CONNECT OK` + a greeting from BOTH VMs is CURRENT
connectivity evidence (B: for retest precondition 4; C: for the NSG-paired
path after the retest — the pairing is ADDITIVE to the retained transitional
security-list rule, so connectivity must hold). A failure on a VM is itself
diagnostic and pauses the retest authorization for reassessment.

Operational caveat: creating the IAM policy (approval A) does NOT prove
command completion — the first approved execution must be verified
end-to-end; a command that is created but never polled or completed means
STOP and a re-reviewed package, never in-place broadening.

## Out of scope

No SSH-source update, no console/credential change, no reboot, no agent
plugin reconfiguration, no IAM change beyond approval A's single policy, no
MySQL change, no security-list change, and no MYSQL-NSG-RETEST
authorization (that remains the separate, later record).
