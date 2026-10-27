// Copyright (c) HashiCorp, Inc.
// SPDX-License-Identifier: BUSL-1.1

package oci

import (
	"bytes"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/hashicorp/terraform/internal/addrs"
	"github.com/hashicorp/terraform/internal/states"
	"github.com/hashicorp/terraform/internal/states/statefile"
	"github.com/hashicorp/terraform/internal/states/statemgr"
	"github.com/zclconf/go-cty/cty"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/objectstorage"
)

// These tests exercise the real OCI backend (Workspaces, StateMgr, RemoteClient)
// against an in-memory mock of the Object Storage REST API. They reproduce the
// destination half of `terraform init -migrate-state` for the default workspace
// without touching any real OCI resources:
//
//	Meta.backendMigrateState -> backendMigrateState_s_s
//	  -> Destination.StateMgr("default")
//	  -> destinationState.RefreshState()
//	  -> statemgr.Migrate(dst, src)          // dst.WriteStateForMigration(f, true)
//	  -> destinationState.PersistState(nil)

const reproBucket = "eventforge-tfstate-repro"
const reproNamespace = "repronamespace"
const reproStateKey = "bootstrap/terraform.tfstate"

const reproSourceLineage = "11111111-2222-3333-4444-555555555555"

const reproSourceSerial uint64 = 17

// ociMockStore is an in-memory stand-in for a versioned OCI bucket.
type ociMockStore struct {
	mu       sync.Mutex
	objects  map[string][][]byte // object name -> version history (append-only)
	etagSeq  int
	requests []string
}

func newOCIMockStore() *ociMockStore {
	return &ociMockStore{objects: make(map[string][][]byte)}
}

func (s *ociMockStore) record(method, name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requests = append(s.requests, method+" "+name)
}

func (s *ociMockStore) get(name string) ([]byte, string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	versions := s.objects[name]
	if len(versions) == 0 {
		return nil, "", false
	}
	return versions[len(versions)-1], s.etagFor(name, len(versions)-1), true
}

func (s *ociMockStore) etagFor(name string, version int) string {
	return fmt.Sprintf("etag-%s-%d", strings.ReplaceAll(name, "/", "_"), version+1)
}

func (s *ociMockStore) put(name string, data []byte) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.objects[name] = append(s.objects[name], append([]byte(nil), data...))
	return s.etagFor(name, len(s.objects[name])-1)
}

func (s *ociMockStore) exists(name string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.objects[name]) > 0
}

func (s *ociMockStore) delete(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.objects, name)
}

func (s *ociMockStore) namesWithPrefix(prefix string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for name := range s.objects {
		if strings.HasPrefix(name, prefix) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

func (s *ociMockStore) stateObjectVersionCount(name string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.objects[name])
}

// handler serves the subset of the Object Storage API the backend uses.
func (s *ociMockStore) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("opc-request-id", "mock-req")
		// The versions endpoint lives at /b/{bucket}/objectversions, outside
		// the /o object path; route it before the generic prefix trim.
		versionsBase := "/n/" + reproNamespace + "/b/" + reproBucket + "/objectversions"
		if r.URL.Path == versionsBase {
			s.handleListVersions(w, r)
			return
		}
		const base = "/n/" + reproNamespace + "/b/" + reproBucket + "/o"
		if !strings.HasPrefix(r.URL.Path, base) {
			http.Error(w, `{"code":"NotAuthorizedOrNotFound","message":"unknown path"}`, http.StatusNotFound)
			return
		}
		rest := strings.TrimPrefix(r.URL.Path, base)

		if rest == "" || rest == "/" {
			s.handleList(w, r)
			return
		}
		name := strings.TrimPrefix(rest, "/")

		switch r.Method {
		case http.MethodHead:
			s.record("HEAD", name)
			if data, etag, ok := s.get(name); ok {
				w.Header().Set("ETag", etag)
				w.Header().Set("Content-Length", fmt.Sprint(len(data)))
				w.WriteHeader(http.StatusOK)
			} else {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusNotFound)
				fmt.Fprint(w, `{"code":"ObjectNotFound","message":"object not found"}`)
			}
		case http.MethodGet:
			s.record("GET", name)
			if data, etag, ok := s.get(name); ok {
				sum := md5.Sum(data)
				w.Header().Set("ETag", etag)
				w.Header().Set("Content-MD5", base64.StdEncoding.EncodeToString(sum[:]))
				w.Header().Set("Content-Length", fmt.Sprint(len(data)))
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write(data)
			} else {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusNotFound)
				fmt.Fprint(w, `{"code":"ObjectNotFound","message":"object not found"}`)
			}
		case http.MethodPut:
			ifNoneMatch := r.Header.Get("If-None-Match")
			if ifNoneMatch == "*" && s.exists(name) {
				s.record("PUT-CONFLICT", name)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusConflict)
				fmt.Fprint(w, `{"code":"EntityAlreadyExists","message":"object exists"}`)
				return
			}
			body, _ := io.ReadAll(r.Body)
			s.record("PUT", name)
			etag := s.put(name, body)
			w.Header().Set("ETag", etag)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, `{"etag":%q}`, etag)
		case http.MethodDelete:
			etag, ok := func() (string, bool) {
				data, etag, ok := s.get(name)
				if !ok {
					return "", false
				}
				_ = data
				return etag, true
			}()
			if !ok {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusNotFound)
				fmt.Fprint(w, `{"code":"ObjectNotFound","message":"object not found"}`)
				return
			}
			if ifMatch := r.Header.Get("If-Match"); ifMatch != "" && ifMatch != etag {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusPreconditionFailed)
				fmt.Fprint(w, `{"code":"PreconditionFailed","message":"etag mismatch"}`)
				return
			}
			s.record("DELETE", name)
			s.delete(name)
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, `{"code":"MethodNotAllowed","message":"method"}`, http.StatusBadRequest)
		}
	}
}

// handleListVersions serves GET .../objectversions (used by the documented
// version-recovery procedure).
func (s *ociMockStore) handleListVersions(w http.ResponseWriter, r *http.Request) {
	prefix := r.URL.Query().Get("prefix")
	s.record("LIST-VERSIONS", prefix)
	type versionSummary struct {
		Name      string `json:"name"`
		VersionID string `json:"versionId"`
		Size      int64  `json:"size"`
	}
	items := make([]versionSummary, 0)
	for _, name := range s.namesWithPrefix(prefix) {
		s.mu.Lock()
		history := s.objects[name]
		for i, data := range history {
			items = append(items, versionSummary{
				Name:      name,
				VersionID: s.etagFor(name, i),
				Size:      int64(len(data)),
			})
		}
		s.mu.Unlock()
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"items": items})
}

func (s *ociMockStore) handleList(w http.ResponseWriter, r *http.Request) {	prefix := r.URL.Query().Get("prefix")
	s.record("LIST", prefix)
	names := s.namesWithPrefix(prefix)
	type objectSummary struct {
		Name string `json:"name"`
		Size int64  `json:"size"`
		ETag string `json:"etag"`
	}
	objects := make([]objectSummary, 0, len(names))
	for _, name := range names {
		data, _, _ := s.get(name)
		objects = append(objects, objectSummary{Name: name, Size: int64(len(data)), ETag: "listed"})
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"objects":       objects,
		"nextStartWith": nil,
	})
}

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

func writeMigrationSourceManager(t *testing.T) statemgr.Full {
	t.Helper()
	var buf bytes.Buffer
	f := statefile.New(migrationReproState(), reproSourceLineage, reproSourceSerial)
	if err := statefile.Write(f, &buf); err != nil {
		t.Fatalf("writing source statefile: %s", err)
	}
	path := filepath.Join(t.TempDir(), "source.tfstate")
	if err := os.WriteFile(path, buf.Bytes(), 0600); err != nil {
		t.Fatalf("writing source state file: %s", err)
	}
	src := statemgr.NewFilesystem(path)
	if err := src.RefreshState(); err != nil {
		t.Fatalf("refreshing source manager: %s", err)
	}
	return src
}

func fetchPersistedRemoteFile(t *testing.T, store *ociMockStore) *statefile.File {
	t.Helper()
	data, _, ok := store.get(reproStateKey)
	if !ok {
		t.Fatalf("state object %q was never written to the mock bucket", reproStateKey)
	}
	f, err := statefile.Read(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("persisted object is not a valid state file: %s", err)
	}
	return f
}

func assertMetadataPreserved(t *testing.T, persisted *statefile.File, src statemgr.Full) {
	t.Helper()
	sourceMeta := src.(statemgr.PersistentMeta).StateSnapshotMeta()
	if persisted.Lineage != sourceMeta.Lineage {
		t.Errorf("lineage was reset: want %q, got %q", sourceMeta.Lineage, persisted.Lineage)
	}
	if persisted.Serial != sourceMeta.Serial+1 {
		t.Errorf("serial was reset: want %d (source serial %d + 1 write), got %d",
			sourceMeta.Serial+1, sourceMeta.Serial, persisted.Serial)
	}
	srcState := src.State()
	if !statefile.StatesMarshalEqual(persisted.State, srcState) {
		t.Errorf("resource data changed during migration")
	}
}

// TestDefaultWorkspaceStateMgrLeavesAbsentStateAbsent verifies the
// initialization path finding: for the default workspace, Workspaces()
// always reports the workspace as existing, so StateMgr skips its
// create-and-refresh branch and the absent remote object stays absent.
func TestDefaultWorkspaceStateMgrLeavesAbsentStateAbsent(t *testing.T) {
	store := newOCIMockStore()
	srv := httptest.NewServer(store.handler())
	defer srv.Close()

	b := newMockOCIBackendWithServer(t, store, srv)

	workspaces, err := b.Workspaces()
	if err != nil {
		t.Fatalf("Workspaces: %s", err)
	}
	foundDefault := false
	for _, ws := range workspaces {
		if ws == "default" {
			foundDefault = true
		}
	}
	if !foundDefault {
		t.Fatalf("Workspaces() = %v, want it to contain \"default\" even for an empty bucket", workspaces)
	}

	mgr, err := b.StateMgr("default")
	if err != nil {
		t.Fatalf("StateMgr: %s", err)
	}
	if state := mgr.State(); state != nil && !state.Empty() {
		t.Fatalf("expected empty/nil state from absent remote, got non-empty state")
	}
	if store.stateObjectVersionCount(reproStateKey) != 0 {
		t.Fatalf("StateMgr wrote the state object for the default workspace; expected the absent object to stay absent (this is what makes the subsequent migration hit the metadata reset)")
	}
}

// TestMigrationToAbsentDefaultWorkspace_PreservesMetadata reproduces the full
// destination sequence of `terraform init -migrate-state` (local -> OCI,
// default workspace, absent destination object) and verifies the persisted
// snapshot keeps the source lineage and advances the serial by one.
//
// On Terraform 1.12.2 this fails: the persisted snapshot carries a freshly
// generated lineage and serial 1, while the resource data is preserved.
func TestMigrationToAbsentDefaultWorkspace_PreservesMetadata(t *testing.T) {
	store := newOCIMockStore()
	srv := httptest.NewServer(store.handler())
	defer srv.Close()

	b := newMockOCIBackendWithServer(t, store, srv)

	dst, err := b.StateMgr("default")
	if err != nil {
		t.Fatalf("StateMgr: %s", err)
	}
	if err := dst.RefreshState(); err != nil {
		t.Fatalf("destination RefreshState: %s", err)
	}

	src := writeMigrationSourceManager(t)

	// Exactly the two calls backendMigrateState_s_s makes after confirmation:
	if err := statemgr.Migrate(dst, src); err != nil {
		t.Fatalf("statemgr.Migrate: %s", err)
	}
	if err := dst.PersistState(nil); err != nil {
		t.Fatalf("destination PersistState: %s", err)
	}

	persisted := fetchPersistedRemoteFile(t, store)
	assertMetadataPreserved(t, persisted, src)

	if got := store.stateObjectVersionCount(reproStateKey); got != 1 {
		t.Errorf("expected exactly one state object version, got %d", got)
	}
}

// TestMigrationToPreInitializedWorkspace_PreservesMetadata is the contrast
// case: if the destination object already exists (because StateMgr's
// initialization branch ran for a named workspace, or an earlier init created
// the object), the metadata is preserved as documented.
func TestMigrationToPreInitializedWorkspace_PreservesMetadata(t *testing.T) {
	store := newOCIMockStore()
	srv := httptest.NewServer(store.handler())
	defer srv.Close()

	// Pre-seed an empty initialized state, as the backend's StateMgr
	// create-branch would have written for a non-default workspace.
	var buf bytes.Buffer
	if err := statefile.Write(statefile.New(states.NewState(), "preinit-lineage", 1), &buf); err != nil {
		t.Fatalf("seeding empty state: %s", err)
	}
	store.put(reproStateKey, buf.Bytes())

	b := newMockOCIBackendWithServer(t, store, srv)

	dst, err := b.StateMgr("default")
	if err != nil {
		t.Fatalf("StateMgr: %s", err)
	}
	if err := dst.RefreshState(); err != nil {
		t.Fatalf("destination RefreshState: %s", err)
	}

	src := writeMigrationSourceManager(t)

	if err := statemgr.Migrate(dst, src); err != nil {
		t.Fatalf("statemgr.Migrate: %s", err)
	}
	if err := dst.PersistState(nil); err != nil {
		t.Fatalf("destination PersistState: %s", err)
	}

	assertMetadataPreserved(t, fetchPersistedRemoteFile(t, store), src)
}

// newMockOCIBackendWithServer is newMockOCIBackend with the mock server host
// plumbed into the ObjectStorageClient used by every RemoteClient the backend
// constructs.
func newMockOCIBackendWithServer(t *testing.T, store *ociMockStore, srv *httptest.Server) *Backend {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generating RSA key: %s", err)
	}
	pemKey := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	provider := common.NewRawConfigurationProvider(
		"ocid1.tenancy.oc1..repro", "ocid1.user.oc1..repro", "eu-repro-1",
		"00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff", string(pemKey), nil,
	)
	osClient, err := objectstorage.NewObjectStorageClientWithConfigurationProvider(provider)
	if err != nil {
		t.Fatalf("building ObjectStorageClient: %s", err)
	}
	osClient.Host = srv.URL

	b := &Backend{
		bucket:             reproBucket,
		key:                reproStateKey,
		namespace:          reproNamespace,
		workspaceKeyPrefix: "env:",
		client: &RemoteClient{
			objectStorageClient: &osClient,
			bucketName:          reproBucket,
			namespace:           reproNamespace,
		},
	}
	return b
}
