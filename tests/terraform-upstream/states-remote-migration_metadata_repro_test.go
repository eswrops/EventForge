// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: BUSL-1.1

package remote

import (
	"bytes"
	"fmt"
	"testing"

	"github.com/hashicorp/go-uuid"
	"github.com/zclconf/go-cty/cty"

	"github.com/hashicorp/terraform/internal/addrs"
	"github.com/hashicorp/terraform/internal/states"
	"github.com/hashicorp/terraform/internal/states/statefile"
)

// These tests document and verify the migration metadata contract that
// backendMigrateState_s_s relies on when copying state into a remote.State
// destination (internal/command/meta_backend_migrate.go):
//
//	statemgr.Migrate(dst, src)  -> dst.WriteStateForMigration(srcFile, true)
//	dst.PersistState(nil)
//
// statemgr.Migrate's doc comment promises "preserving snapshot metadata
// (serial and lineage) where possible". WriteStateForMigration stages the
// source lineage/serial into the manager; PersistState must not discard them
// when the destination's remote object does not exist yet.

const reproSourceLineage = "11111111-2222-3333-4444-555555555555"

const reproSourceSerial uint64 = 17

// migrationReproState returns a small but representative state: one managed
// resource instance and one root output.
func migrationReproState() *states.State {
	state := states.NewState()
	root := state.RootModule()
	root.SetResourceInstanceCurrent(
		addrs.Resource{
			Mode: addrs.ManagedResourceMode,
			Type: "terraform_data",
			Name: "probe",
		}.Instance(addrs.NoKey),
		&states.ResourceInstanceObjectSrc{
			Status:    states.ObjectReady,
			AttrsJSON: []byte(`{"id":"probe-1","input":"seed","output":"seed"}`),
		},
		addrs.AbsProviderConfig{
			Provider: addrs.NewDefaultProvider("terraform"),
			Module:   addrs.RootModule,
		},
	)
	state.SetOutputValue(
		addrs.OutputValue{Name: "summary"}.Absolute(addrs.RootModuleInstance),
		cty.StringVal("seed"), false,
	)
	return state
}

func migrationReproSourceFile(t *testing.T) *statefile.File {
	t.Helper()
	return statefile.New(migrationReproState(), reproSourceLineage, reproSourceSerial)
}

// persistedRemoteFile retrieves and parses what the client actually stored.
func persistedRemoteFile(t *testing.T, c *mockClient) *statefile.File {
	t.Helper()
	if c.current == nil {
		t.Fatalf("nothing was persisted to the remote client")
	}
	f, err := statefile.Read(bytes.NewReader(c.current))
	if err != nil {
		t.Fatalf("persisted data is not a valid state file: %s", err)
	}
	return f
}

func assertMetadataPreserved(t *testing.T, persisted, source *statefile.File) {
	t.Helper()
	if persisted.Lineage != source.Lineage {
		t.Errorf("lineage was reset: want %q, got %q", source.Lineage, persisted.Lineage)
	}
	if persisted.Serial != source.Serial+1 {
		t.Errorf("serial was reset: want %d (source serial %d + 1 write), got %d",
			source.Serial+1, source.Serial, persisted.Serial)
	}
	if !statefile.StatesMarshalEqual(persisted.State, source.State) {
		t.Errorf("resource data changed during migration")
	}
}

// TestMigrationToAbsentRemote_PreservesMetadata reproduces the destination
// sequence of `terraform init -migrate-state` (backendMigrateState_s_s) when
// the destination's remote object does not exist: RefreshState finds nothing,
// WriteStateForMigration stages the source snapshot metadata, PersistState
// writes it. The persisted snapshot must keep the staged lineage and advance
// the serial by exactly one.
func TestMigrationToAbsentRemote_PreservesMetadata(t *testing.T) {
	client := &mockClient{} // remote object absent
	mgr := &State{Client: client}

	if err := mgr.RefreshState(); err != nil {
		t.Fatalf("RefreshState: %s", err)
	}

	source := migrationReproSourceFile(t)
	if err := mgr.WriteStateForMigration(source, true); err != nil {
		t.Fatalf("WriteStateForMigration: %s", err)
	}
	if err := mgr.PersistState(nil); err != nil {
		t.Fatalf("PersistState: %s", err)
	}

	assertMetadataPreserved(t, persistedRemoteFile(t, client), source)
}

// TestMigrationWithoutRefresh_PreservesMetadata covers the variant where the
// destination manager is never explicitly refreshed before the migration
// write (as with the OCI backend's default workspace, whose StateMgr skips
// its initialization branch because Workspaces always reports "default").
// PersistState then refreshes internally and must still preserve the staged
// metadata when the remote object is absent.
func TestMigrationWithoutRefresh_PreservesMetadata(t *testing.T) {
	client := &mockClient{} // remote object absent
	mgr := &State{Client: client}

	source := migrationReproSourceFile(t)
	if err := mgr.WriteStateForMigration(source, true); err != nil {
		t.Fatalf("WriteStateForMigration: %s", err)
	}
	if err := mgr.PersistState(nil); err != nil {
		t.Fatalf("PersistState: %s", err)
	}

	assertMetadataPreserved(t, persistedRemoteFile(t, client), source)
}

// TestMigrationDestinationPreInitialized_PreservesMetadata is the contrast
// case: the destination already holds an (empty) initialized state, so
// PersistState takes the readState != nil branch, which does preserve the
// staged lineage and only increments the serial.
func TestMigrationDestinationPreInitialized_PreservesMetadata(t *testing.T) {
	var buf bytes.Buffer
	existing := statefile.New(states.NewState(), "preinit-lineage", 1)
	if err := statefile.Write(existing, &buf); err != nil {
		t.Fatalf("writing pre-existing empty state: %s", err)
	}
	client := &mockClient{current: buf.Bytes()}
	mgr := &State{Client: client}

	if err := mgr.RefreshState(); err != nil {
		t.Fatalf("RefreshState: %s", err)
	}

	source := migrationReproSourceFile(t)
	if err := mgr.WriteStateForMigration(source, true); err != nil {
		t.Fatalf("WriteStateForMigration: %s", err)
	}
	if err := mgr.PersistState(nil); err != nil {
		t.Fatalf("PersistState: %s", err)
	}

	assertMetadataPreserved(t, persistedRemoteFile(t, client), source)
}

// TestPersistStateGeneratesLineageForGenuinelyNewState pins the legitimate
// behavior the same code must retain: a manager that never received a staged
// migration must mint a fresh lineage and serial 1.
func TestPersistStateGeneratesLineageForGenuinelyNewState(t *testing.T) {
	client := &mockClient{} // remote object absent
	mgr := &State{Client: client}

	if err := mgr.RefreshState(); err != nil {
		t.Fatalf("RefreshState: %s", err)
	}
	if err := mgr.WriteState(migrationReproState()); err != nil {
		t.Fatalf("WriteState: %s", err)
	}
	if err := mgr.PersistState(nil); err != nil {
		t.Fatalf("PersistState: %s", err)
	}

	persisted := persistedRemoteFile(t, client)
	if persisted.Lineage == "" {
		t.Errorf("expected a freshly generated lineage for a brand new state, got empty")
	}
	if _, err := uuid.ParseUUID(persisted.Lineage); err != nil {
		t.Errorf("expected generated lineage to be a UUID, got %q", persisted.Lineage)
	}
	if persisted.Serial != 1 {
		t.Errorf("expected serial 1 for a brand new state, got %d", persisted.Serial)
	}
}

// failGetClient fails every Get with the given error (Put/Delete delegate to
// an embedded mockClient so a persist can be retried after fixing the fault).
type failGetClient struct {
	mockClient
	getErr error
}

func (c *failGetClient) Get() (*Payload, error) { return nil, c.getErr }

// failPutClient fails the first N Put calls, then delegates to the embedded
// mockClient.
type failPutClient struct {
	mockClient
	remainingFailures int
	putErr            error
}

func (c *failPutClient) Put(data []byte) error {
	if c.remainingFailures > 0 {
		c.remainingFailures--
		return c.putErr
	}
	return c.mockClient.Put(data)
}

// TestMigrationDestinationAppearsBeforePersist_RefusesOverwrite covers the
// concurrency window between the destination-existence check and persistence:
// a concurrent writer creates remote state after the migration staged its
// metadata but before PersistState runs. The persist must refuse to overwrite
// the appeared snapshot rather than silently replacing it (without this
// guard the staged resources would be written under the appeared snapshot's
// lineage and serial, with no validity check).
func TestMigrationDestinationAppearsBeforePersist_RefusesOverwrite(t *testing.T) {
	client := &mockClient{} // destination absent when the migration stages its metadata
	mgr := &State{Client: client}

	source := migrationReproSourceFile(t)
	if err := mgr.WriteStateForMigration(source, true); err != nil {
		t.Fatalf("WriteStateForMigration: %s", err)
	}

	// A concurrent writer creates the destination between the migration's
	// staging and this manager's persist; the manager has not refreshed,
	// so readState is still nil.
	var appeared bytes.Buffer
	if err := statefile.Write(statefile.New(migrationReproState(), "concurrent-writer-lineage", 3), &appeared); err != nil {
		t.Fatalf("seeding concurrently-appeared state: %s", err)
	}
	client.current = appeared.Bytes()

	err := mgr.PersistState(nil)
	if err == nil {
		t.Fatalf("PersistState succeeded despite a remote snapshot appearing mid-flight; expected a conflict error")
	}
	if want := "concurrent-writer-lineage"; !bytes.Contains([]byte(err.Error()), []byte(want)) {
		t.Errorf("conflict error should identify the appeared lineage %q, got: %s", want, err)
	}

	// The appeared snapshot must be untouched.
	if f := persistedRemoteFile(t, client); f.Lineage != "concurrent-writer-lineage" || f.Serial != 3 {
		t.Errorf("appeared snapshot was modified: lineage %q serial %d", f.Lineage, f.Serial)
	}
}

// TestPersistStatePropagatesGetFailure pins that a failed existence check
// aborts the persist instead of being treated as "destination absent".
func TestPersistStatePropagatesGetFailure(t *testing.T) {
	client := &failGetClient{getErr: fmt.Errorf("mock get outage")}
	mgr := &State{Client: client}

	if err := mgr.WriteState(migrationReproState()); err != nil {
		t.Fatalf("WriteState: %s", err)
	}
	if err := mgr.PersistState(nil); err == nil {
		t.Fatalf("PersistState succeeded despite a failed existence check")
	}
	if client.current != nil {
		t.Fatalf("Put was attempted despite a failed existence check")
	}
}

// TestPutFailureAllowsRetry pins that a failed Put returns the error, leaves
// the manager ready to retry, and that the retry persists the staged metadata
// correctly.
func TestPutFailureAllowsRetry(t *testing.T) {
	client := &failPutClient{remainingFailures: 1, putErr: fmt.Errorf("mock put outage")}
	mgr := &State{Client: client}

	if err := mgr.RefreshState(); err != nil {
		t.Fatalf("RefreshState: %s", err)
	}
	source := migrationReproSourceFile(t)
	if err := mgr.WriteStateForMigration(source, true); err != nil {
		t.Fatalf("WriteStateForMigration: %s", err)
	}
	if err := mgr.PersistState(nil); err == nil {
		t.Fatalf("first PersistState succeeded despite the Put failure")
	}
	if client.current != nil {
		t.Fatalf("failed Put must not have persisted anything")
	}
	if err := mgr.PersistState(nil); err != nil {
		t.Fatalf("retry PersistState after the Put recovered: %s", err)
	}
	// The failed attempt may consume a serial number (it does, consistently
	// with the pre-existing failed-persist behavior on the
	// existing-destination path), so assert the recovery property: the
	// lineage is preserved, the serial only moved forward, and the resource
	// data is intact.
	persisted := persistedRemoteFile(t, &client.mockClient)
	if persisted.Lineage != source.Lineage {
		t.Errorf("lineage was reset: want %q, got %q", source.Lineage, persisted.Lineage)
	}
	if persisted.Serial <= source.Serial {
		t.Errorf("serial did not advance: source %d, persisted %d", source.Serial, persisted.Serial)
	}
	if !statefile.StatesMarshalEqual(persisted.State, source.State) {
		t.Errorf("resource data changed across the retried persist")
	}
}
