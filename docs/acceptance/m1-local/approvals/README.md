# M1-LOCAL approval records

Production mutations are authorized by **written records in this directory plus the
operator's matching environment attestation** — never by an environment variable alone,
never by a passed technical policy check alone. Each record is committed (part of the
acceptance history) and is verified by the executing script before anything runs.

## Contract

A record must contain, in plain text:

- `GATE: <gate marker>` — exactly one of `OCI-IMPORT`, `PLATFORM-APPLY`,
  `PLATFORM-INIT-EXISTING-STATE`;
- `APPROVER: <name>` — the operator's name as it will appear in the env attestation
  (`M1_IMPORT_APPROVED_BY` / `M1_APPLY_APPROVED_BY`);
- the gate-specific bindings the script verifies:
  - **OCI-IMPORT**: the current commit SHA and all eight resource addresses;
  - **PLATFORM-APPLY**: the saved plan's SHA-256 and the source commit SHA;
  - **PLATFORM-INIT-EXISTING-STATE**: the live state lineage being acknowledged.
- a dated statement that the operator reviewed the referenced artifacts.

A record without the exact bindings fails closed; a mismatching `M1_*_APPROVED_BY`
attestation fails closed. Templates: [oci-import-approval.template](oci-import-approval.template),
[platform-apply-approval.template](platform-apply-approval.template).

## Status

No approval record exists yet. `platform/terraform.tfstate` has never been written.
