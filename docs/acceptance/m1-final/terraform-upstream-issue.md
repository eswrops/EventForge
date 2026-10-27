# Upstream report draft (sanitized)

Target repository: `hashicorp/terraform`. Everything below is sanitized:
synthetic lineage UUID, no bucket/namespace/region/tenant identifiers, no
credentials, no cloud account required. Verified against the public Terraform
1.12.2 source; reproduction is a Go unit test.

---

**Title:** `remote.State.PersistState discards lineage/serial staged by WriteStateForMigration when the destination has no existing remote state (init -migrate-state, state push)`

**Terraform version:** 1.12.2 (source-verified; the involved code is shared by
all `internal/states/remote`-based backends)

### Summary

When migrating state into a remote backend whose destination object does not
exist yet, `terraform init -migrate-state` completes successfully but the
persisted snapshot gets a freshly generated `lineage` and `serial` 1 instead of
preserving the source snapshot's metadata. Resource data is preserved
byte-for-byte. `statemgr.Migrate`'s contract — "preserving snapshot metadata
(serial and lineage) where possible" (`internal/states/statemgr/migrate.go`) —
is violated. `terraform state push` to a key with no existing remote object
hits the same reset.

### Reproduction

Unit-level reproduction with an in-memory `remote.Client` (no cloud account):

```go
client := &mockClient{} // Get() returns (nil, nil) while empty, like all real clients on 404
mgr := &remote.State{Client: client}

mgr.RefreshState() // destination absent — as backendMigrateState_s_s does

source := statefile.New(someState, "11111111-2222-3333-4444-555555555555", 17)
mgr.WriteStateForMigration(source, true) // what statemgr.Migrate calls (force=true)
mgr.PersistState(nil)                    // what backendMigrateState_s_s calls next

// Read back client's stored bytes with statefile.Read:
// want lineage "11111111-2222-3333-4444-555555555555", serial 18;
// got  lineage "23b0ec18-11d2-2484-c5a9-bfb8057a9d7f" (example), serial 1.
// Resource data identical.
```

Full regression tests (including an end-to-end run through the real `oci`
backend driven by a mock Object Storage HTTP server) are available and fail on
unpatched 1.12.2 and pass with the fix below.

The manager's own debug logging shows the clobber directly:

```
[DEBUG] states/remote: state read serial is: 0; serial is: 17
[DEBUG] states/remote: after refresh, state read serial is: 0; serial is: 0
[DEBUG] states/remote: state read lineage is: ; lineage is: 11111111-2222-3333-4444-555555555555
[DEBUG] states/remote: after refresh, state read lineage is: ; lineage is:
```

### Root cause

`internal/states/remote/state.go`:

- `WriteStateForMigration` stages the source snapshot by setting `s.state`,
  `s.lineage`, `s.serial` (the `read*` fields remain untouched).
- `PersistState`, in its `readState == nil` branch, calls `s.refreshState()`.
  When the remote holds no snapshot, `refreshState` **unconditionally resets
  the current fields** `s.lineage = ""` and `s.serial = 0` — discarding the
  staged migration metadata.
- The subsequent `if s.lineage == ""` check then misreads the wiped values as
  "no state snapshot present yet" and mints a new lineage plus `serial++`
  (0 + 1 = 1).

The staging itself is sound: when the destination already holds a (even empty)
snapshot, `PersistState` takes the `readState != nil` branch and correctly
preserves the staged lineage, advancing the serial (17 → 18).

Related finding: `oci` backend `Workspaces()` unconditionally includes the
`"default"` workspace, so for the default workspace its `StateMgr` never runs
the absent-state initialization/refresh branch. That is why migrations into
the OCI default workspace reliably hit the `readState == nil` path (confirmed
end-to-end against a mock server). Other backends that do initialize the
destination object during `StateMgr` mask the bug.

Also affected: `terraform state push` onto an absent remote key
(`internal/command/state_push.go` uses `statemgr.Import` + `PersistState`).

### Impact

- Post-migration snapshots cannot be correlated with pre-migration backups by
  lineage; audit tooling that keys on lineage loses continuity.
- Serial continuity restarts at 1; comparisons against pre-migration serials
  (or snapshots pulled by third-party tooling) are meaningless and can defeat
  optimistic-concurrency assumptions in external tooling.
- Silent: the command exits successfully with no hint that metadata changed.

### Suggested fix

Two small hunks in `PersistState`'s `readState == nil` branch:

1. **Preserve staged metadata across the internal refresh.** `refreshState`
   resets `s.lineage`/`s.serial` on a nil payload; capture them before the
   call and restore them (serial + 1) when the remote turns out to be absent
   and a migration staged metadata:

```go
stagedLineage, stagedSerial := s.lineage, s.serial
err := s.refreshState()
if err != nil { ... }
if s.lineage == "" { // no remote snapshot
    if stagedLineage != "" {
        s.lineage = stagedLineage
        s.serial = stagedSerial + 1
    } else {
        lineage, err := uuid.GenerateUUID()
        ...
        s.lineage = lineage
        s.serial++
    }
}
```

The serial advances by one on the persisting write, consistent with the
existing-destination path. Fresh-state lineage minting is unchanged.

2. **Refuse to overwrite a destination that appeared mid-flight.** If, after
   the internal refresh, a remote snapshot exists while migration metadata was
   staged (`s.lineage != "" && stagedLineage != ""`), return an error instead
   of silently overwriting the appeared snapshot (the current behavior writes
   staged resources under the appeared snapshot's lineage/serial with no
   serial advance and no `CheckValidImport`). `state push` and
   `init -migrate-state` always refresh before staging, so legitimate flows
   are unaffected; the guard protects only the race window.

With both hunks the reproduction tests pass and the full pre-existing
`internal/states/...` suites pass unchanged.

### References

- `internal/states/remote/state.go` — `WriteStateForMigration`, `refreshState`, `PersistState`
- `internal/states/statemgr/migrate.go` — `Migrate`, the metadata-preservation contract
- `internal/command/meta_backend_migrate.go` — `backendMigrateState_s_s` call sequence
- `internal/command/state_push.go` — `Import` + `PersistState` path
