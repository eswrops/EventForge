// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: BUSL-1.1

package oci

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/hashicorp/terraform/internal/states"
	"github.com/hashicorp/terraform/internal/states/statefile"
	"github.com/hashicorp/terraform/internal/states/statemgr"
	"github.com/oracle/oci-go-sdk/v65/objectstorage"
)

// Offline lifecycle coverage for the OCI backend against the in-memory mock
// Object Storage server, mirroring the live disposable-key probes documented
// in the deployment runbook (lock acquisition, concurrent contention, version
// recovery by copying a prior version, and authorization denial) without
// touching any real OCI resources.

// TestOfflineStateLockContentionAndRelease holds a lock with one manager and
// verifies a second manager's lock attempt fails while the lock is held, then
// succeeds after release.
func TestOfflineStateLockContentionAndRelease(t *testing.T) {
	store := newOCIMockStore()
	srv := httptest.NewServer(store.denyAwareHandler())
	defer srv.Close()

	b1 := newMockOCIBackendWithServer(t, store, srv)
	b2 := newMockOCIBackendWithServer(t, store, srv)

	mgr1, err := b1.StateMgr("default")
	if err != nil {
		t.Fatalf("StateMgr (holder): %s", err)
	}
	mgr2, err := b2.StateMgr("default")
	if err != nil {
		t.Fatalf("StateMgr (contender): %s", err)
	}

	info1 := statemgr.NewLockInfo()
	info1.Operation = "offline-lock-probe"
	lockID1, err := mgr1.Lock(info1)
	if err != nil {
		t.Fatalf("initial lock: %s", err)
	}

	info2 := statemgr.NewLockInfo()
	info2.Operation = "offline-lock-probe-contender"
	_, err = mgr2.Lock(info2)
	if err == nil {
		t.Fatalf("second lock succeeded while the first lock was held; expected a lock error")
	}
	var lockErr *statemgr.LockError
	if !asLockError(err, &lockErr) {
		t.Fatalf("expected statemgr.LockError from contender, got %T: %s", err, err)
	}
	if lockErr.Info == nil || lockErr.Info.Operation != "offline-lock-probe" {
		t.Errorf("contender's lock error should surface the holder's lock info, got %+v", lockErr.Info)
	}

	if err := mgr1.Unlock(lockID1); err != nil {
		t.Fatalf("release: %s", err)
	}

	lockID2, err := mgr2.Lock(info2)
	if err != nil {
		t.Fatalf("lock after release: %s", err)
	}
	if err := mgr2.Unlock(lockID2); err != nil {
		t.Fatalf("release after re-lock: %s", err)
	}
}

// TestOfflineStateVersionRecovery writes two state versions to the mock
// bucket, lists them through the real client, restores the prior version by
// copying it over the live key (the documented recovery procedure; never
// state push -force), and verifies a fresh manager reads the restored
// lineage/serial.
func TestOfflineStateVersionRecovery(t *testing.T) {
	store := newOCIMockStore()
	srv := httptest.NewServer(store.denyAwareHandler())
	defer srv.Close()

	const lineage = "11111111-2222-3333-4444-555555555555"
	v1 := mustStatefileBytes(t, migrationReproState(), lineage, 5)
	v2 := mustStatefileBytes(t, migrationReproState(), lineage, 6)
	store.put(reproStateKey, v1)
	store.put(reproStateKey, v2)

	b := newMockOCIBackendWithServer(t, store, srv)
	osClient := b.client.objectStorageClient

	versions, err := osClient.ListObjectVersions(context.Background(), listVersionsRequest())
	if err != nil {
		t.Fatalf("ListObjectVersions: %s", err)
	}
	var stateVersions []string
	for _, item := range versions.Items {
		if *item.Name == reproStateKey {
			stateVersions = append(stateVersions, *item.VersionId)
		}
	}
	if len(stateVersions) != 2 {
		t.Fatalf("expected 2 state object versions, got %d (%v)", len(stateVersions), stateVersions)
	}

	// Recovery: copy the prior version's content onto the live key.
	store.put(reproStateKey, v1)

	mgr, err := b.StateMgr("default")
	if err != nil {
		t.Fatalf("StateMgr: %s", err)
	}
	if err := mgr.RefreshState(); err != nil {
		t.Fatalf("RefreshState after restore: %s", err)
	}
	meta := mgr.(statemgr.PersistentMeta).StateSnapshotMeta()
	if meta.Lineage != lineage || meta.Serial != 5 {
		t.Errorf("after recovery want lineage %q serial 5, got lineage %q serial %d",
			lineage, meta.Lineage, meta.Serial)
	}
}

// TestOfflineAuthorizationDenial points the backend at a bucket the mock
// server refuses with 403 and verifies the failure surfaces as a distinct
// access error (the offline analogue of the underprivileged-principal probe).
func TestOfflineAuthorizationDenial(t *testing.T) {
	store := newOCIMockStore()
	srv := httptest.NewServer(store.denyAwareHandler())
	defer srv.Close()

	b := newMockOCIBackendWithServer(t, store, srv)
	b.bucket = "denied-bucket"
	b.client.bucketName = "denied-bucket"

	_, err := b.StateMgr("default")
	if err == nil {
		t.Fatalf("expected StateMgr against a denied bucket to fail")
	}
	msg := err.Error()
	if !strings.Contains(msg, "403") && !strings.Contains(msg, "NotAuthorized") && !strings.Contains(msg, "NotAuthenticated") {
		t.Errorf("expected the error to identify an authorization denial (403), got: %s", msg)
	}
	if store.exists(reproStateKey) {
		t.Errorf("denied probe must not write any object")
	}
}

func asLockError(err error, target **statemgr.LockError) bool {
	if e, ok := err.(*statemgr.LockError); ok {
		*target = e
		return true
	}
	return false
}

func mustStatefileBytes(t *testing.T, state *states.State, lineage string, serial uint64) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := statefile.Write(statefile.New(state, lineage, serial), &buf); err != nil {
		t.Fatalf("serializing statefile: %s", err)
	}
	return buf.Bytes()
}

func listVersionsRequest() objectstorage.ListObjectVersionsRequest {
	bucket := reproBucket
	namespace := reproNamespace
	prefix := reproStateKey
	return objectstorage.ListObjectVersionsRequest{
		BucketName:    &bucket,
		NamespaceName: &namespace,
		Prefix:        &prefix,
	}
}

// denyAwareHandler wraps the base handler with a hard 403 for any request
// against the "denied-bucket" bucket, emulating an IAM policy denial.
func (s *ociMockStore) denyAwareHandler() http.HandlerFunc {
	base := s.handler()
	return func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/b/denied-bucket/") {
			w.Header().Set("opc-request-id", "mock-req")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_ = json.NewEncoder(w).Encode(map[string]string{
				"code":    "NotAuthenticated",
				"message": "The required information to complete authentication was not provided or was incorrect.",
			})
			return
		}
		base(w, r)
	}
}
