package thinappviewcore

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/jcalabro/atmos"
	"github.com/jcalabro/atmos/car"
	"github.com/jcalabro/atmos/cbor"
	"github.com/jcalabro/atmos/crypto"
	"github.com/jcalabro/atmos/mst"
	"github.com/jcalabro/atmos/repo"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

const snapshotFixtureDID = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
const snapshotFixturePDS = "https://snapshot-pds.publisher.social"

type snapshotFixture struct {
	t         *testing.T
	key       crypto.PrivateKey
	commit    *repo.Commit
	commitCID cbor.CID
	blocks    map[string]car.Block
	calls     map[string]int
	requested map[string]bool
	document  map[string]any
	mutate    func(string, int, []byte) []byte
	status    func(string, int) int
	extra     bool
	corrupt   bool
}

func newSnapshotFixture(t *testing.T, count int) *snapshotFixture {
	t.Helper()
	key, err := crypto.GenerateP256()
	if err != nil {
		t.Fatal(err)
	}
	store := mst.NewMemBlockStore()
	rp := &repo.Repo{DID: atmos.DID(snapshotFixtureDID), Clock: atmos.NewTIDClock(0), Store: store, Tree: mst.NewTree(store)}
	for i := 0; i < count; i++ {
		if err := rp.Create("site.standard.document", fmt.Sprintf("key%03d", i), map[string]any{"$type": "site.standard.document", "title": fmt.Sprintf("Record %d", i), "link": cbor.ComputeCID(cbor.CodecDagCBOR, []byte("linked")), "bytes": []byte{1, 2}}); err != nil {
			t.Fatal(err)
		}
	}
	if err := rp.Create("app.bsky.feed.post", "excluded", map[string]any{"text": "unrelated"}); err != nil {
		t.Fatal(err)
	}
	commit, err := rp.Commit(key)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := commit.EncodeCBOR()
	if err != nil {
		t.Fatal(err)
	}
	f := &snapshotFixture{t: t, key: key, commit: commit, commitCID: cbor.ComputeCID(cbor.CodecDagCBOR, raw), blocks: map[string]car.Block{}, calls: map[string]int{}, requested: map[string]bool{}}
	for cid, data := range store.All() {
		f.blocks[cid.String()] = car.Block{CID: cid, Data: data}
	}
	f.document = map[string]any{"id": snapshotFixtureDID, "service": []any{map[string]any{"id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": snapshotFixturePDS}}, "verificationMethod": []any{map[string]any{"id": snapshotFixtureDID + "#atproto", "controller": snapshotFixtureDID, "type": "Multikey", "publicKeyMultibase": key.PublicKey().Multibase()}}}
	return f
}
func (f *snapshotFixture) Get(ctx context.Context, target string, headers http.Header, limit, redirects int) (int, http.Header, []byte, error) {
	if err := ctx.Err(); err != nil {
		return 0, nil, nil, err
	}
	u, err := url.Parse(target)
	if err != nil {
		f.t.Fatal(err)
	}
	if headers.Get("Authorization") != "" || redirects != 0 {
		f.t.Fatal("unexpected credential or redirect")
	}
	path := u.Path
	f.calls[path]++
	status := 200
	if f.status != nil {
		status = f.status(path, f.calls[path])
	}
	if status != 200 {
		return status, http.Header{"Retry-After": {"0"}}, []byte(`{"error":"Unavailable"}`), nil
	}
	var body []byte
	switch path {
	case "/" + snapshotFixtureDID:
		body, _ = json.Marshal(f.document)
	case "/xrpc/com.atproto.sync.getRepoStatus":
		body, _ = json.Marshal(map[string]any{"did": snapshotFixtureDID, "active": true})
	case "/xrpc/com.atproto.sync.getLatestCommit":
		body, _ = json.Marshal(map[string]any{"cid": f.commitCID.String(), "rev": f.commit.Rev})
	case "/xrpc/com.atproto.sync.getBlocks":
		var buffer bytes.Buffer
		// getBlocks' CAR header root is not a promise that root is included.
		writer, err := car.NewWriter(&buffer, []cbor.CID{f.commitCID})
		if err != nil {
			f.t.Fatal(err)
		}
		for _, requested := range u.Query()["cids"] {
			f.requested[requested] = true
			if block, ok := f.blocks[requested]; ok {
				if err := writer.WriteBlock(block.CID, block.Data); err != nil {
					f.t.Fatal(err)
				}
			}
		}
		if f.extra {
			raw, _ := cbor.Marshal(map[string]any{"extra": "not requested"})
			writer.WriteBlock(cbor.ComputeCID(cbor.CodecDagCBOR, raw), raw)
		}
		body = buffer.Bytes()
		if f.corrupt && len(body) > 0 {
			body[len(body)-1] ^= 1
		}
	default:
		f.t.Fatalf("unexpected endpoint %s", path)
	}
	if f.mutate != nil {
		body = f.mutate(path, f.calls[path], body)
	}
	return status, http.Header{}, body, nil
}
func (f *snapshotFixture) reader() RepositorySnapshotReader {
	return RepositorySnapshotReader{PDS: &PDSClient{HTTP: f, PLCBase: "https://identity.example"}}
}
func (f *snapshotFixture) replaceCommit(t *testing.T) {
	t.Helper()
	raw, err := f.commit.EncodeCBOR()
	if err != nil {
		t.Fatal(err)
	}
	f.commitCID = cbor.ComputeCID(cbor.CodecDagCBOR, raw)
	f.blocks[f.commitCID.String()] = car.Block{CID: f.commitCID, Data: raw}
}
func TestRepositorySnapshotCompleteSignedTree(t *testing.T) {
	f := newSnapshotFixture(t, 73)
	result, err := f.reader().Read(context.Background(), snapshotFixtureDID, []string{"site.standard.document", "site.standard.entry"})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Records) != 73 || result.CommitCID != f.commitCID.String() || result.PDSBase != snapshotFixturePDS {
		t.Fatal("incorrect complete snapshot envelope")
	}
	for _, record := range result.Records {
		var value map[string]any
		if json.Unmarshal(record.Value, &value) != nil || value["link"].(map[string]any)["$link"] == nil || value["bytes"].(map[string]any)["$bytes"] == nil {
			t.Fatal("ATProto JSON representation lost")
		}
	}
	for cid, block := range f.blocks {
		value, err := cbor.Unmarshal(block.Data)
		if err == nil {
			if object, ok := value.(map[string]any); ok && object["text"] == "unrelated" && f.requested[cid] {
				t.Fatal("unrelated record body fetched")
			}
		}
	}
	if f.calls["/xrpc/com.atproto.sync.getLatestCommit"] != 2 || f.calls["/"+snapshotFixtureDID] != 2 {
		t.Fatal("missing final identity/revision validation")
	}
}
func TestRepositorySnapshotRejectsIncompleteOrUntrustedInputs(t *testing.T) {
	tests := []struct {
		name   string
		change func(*snapshotFixture)
	}{
		{"bad signature", func(f *snapshotFixture) { f.commit.Sig[0] ^= 1; f.replaceCommit(t) }},
		{"wrong DID", func(f *snapshotFixture) {
			f.commit.DID = "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"
			f.commit.Sign(f.key)
			f.replaceCommit(t)
		}},
		{"version two", func(f *snapshotFixture) { f.commit.Version = 2; f.commit.Sign(f.key); f.replaceCommit(t) }},
		{"future revision", func(f *snapshotFixture) {
			f.commit.Rev = string(atmos.NewTIDFromTime(time.Now().Add(time.Hour), 0))
			f.commit.Sign(f.key)
			f.replaceCommit(t)
		}},
		{"missing commit", func(f *snapshotFixture) { delete(f.blocks, f.commitCID.String()) }},
		{"missing tree", func(f *snapshotFixture) { delete(f.blocks, f.commit.Data.String()) }},
		{"missing record", func(f *snapshotFixture) {
			for cid, block := range f.blocks {
				v, e := cbor.Unmarshal(block.Data)
				if e == nil {
					if o, ok := v.(map[string]any); ok && o["title"] != nil {
						delete(f.blocks, cid)
						return
					}
				}
			}
		}},
		{"hash mismatch", func(f *snapshotFixture) { f.corrupt = true }},
		{"unsolicited block", func(f *snapshotFixture) { f.extra = true }},
		{"wrong controller", func(f *snapshotFixture) {
			f.document["verificationMethod"].([]any)[0].(map[string]any)["controller"] = "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"
		}},
		{"unsafe PDS", func(f *snapshotFixture) {
			f.document["service"].([]any)[0].(map[string]any)["serviceEndpoint"] = "http://127.0.0.1"
		}},
		{"inactive", func(f *snapshotFixture) {
			f.mutate = func(path string, n int, b []byte) []byte {
				if strings.HasSuffix(path, "getRepoStatus") {
					return []byte(`{"did":"` + snapshotFixtureDID + `","active":false}`)
				}
				return b
			}
		}},
		{"commit changed", func(f *snapshotFixture) {
			f.mutate = func(path string, n int, b []byte) []byte {
				if strings.HasSuffix(path, "getLatestCommit") && n == 2 {
					v := map[string]any{}
					json.Unmarshal(b, &v)
					v["rev"] = string(atmos.NewTIDNow(1))
					b, _ = json.Marshal(v)
				}
				return b
			}
		}},
		{"PDS changed", func(f *snapshotFixture) {
			f.mutate = func(path string, n int, b []byte) []byte {
				if path == "/"+snapshotFixtureDID && n == 2 {
					return bytes.ReplaceAll(b, []byte(snapshotFixturePDS), []byte("https://changed.publisher.social"))
				}
				return b
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			f := newSnapshotFixture(t, 4)
			test.change(f)
			result, err := f.reader().Read(context.Background(), snapshotFixtureDID, []string{"site.standard.document"})
			if err == nil || len(result.Records) != 0 {
				t.Fatal("unverified snapshot accepted")
			}
			if strings.Contains(err.Error(), snapshotFixtureDID) || strings.Contains(err.Error(), f.commitCID.String()) || strings.Contains(err.Error(), "key000") {
				t.Fatal("error leaked repository identity")
			}
		})
	}
}
func TestRepositorySnapshotRejectsMalformedTreeAndNoncanonicalCommit(t *testing.T) {
	for _, name := range []string{"prefix", "ordering", "invalid path", "unknown commit field", "missing prev", "empty collection"} {
		t.Run(name, func(t *testing.T) {
			f := newSnapshotFixture(t, 2)
			collections := []string{"site.standard.document"}
			if name == "empty collection" {
				collections = nil
			} else if name == "unknown commit field" || name == "missing prev" {
				block := f.blocks[f.commitCID.String()]
				value, err := cbor.Unmarshal(block.Data)
				if err != nil {
					t.Fatal(err)
				}
				object := value.(map[string]any)
				if name == "unknown commit field" {
					object["unknown"] = "unsigned extension"
				} else {
					delete(object, "prev")
				}
				raw, err := cbor.Marshal(object)
				if err != nil {
					t.Fatal(err)
				}
				f.commitCID = cbor.ComputeCID(cbor.CodecDagCBOR, raw)
				f.blocks[f.commitCID.String()] = car.Block{CID: f.commitCID, Data: raw}
			} else {
				value := cbor.ComputeCID(cbor.CodecDagCBOR, []byte("record"))
				path := "site.standard.document/key000"
				prefix := int64(0)
				if name == "invalid path" {
					path = "site.standard.document/invalid/slash"
				}
				if name == "prefix" {
					prefix = 100
				}
				entries := []any{map[string]any{"p": prefix, "k": []byte(path), "v": value, "t": nil}}
				if name == "ordering" {
					entries = append(entries, map[string]any{"p": int64(0), "k": []byte(path), "v": value, "t": nil})
				}
				raw, err := cbor.Marshal(map[string]any{"e": entries, "l": nil})
				if err != nil {
					t.Fatal(err)
				}
				treeCID := cbor.ComputeCID(cbor.CodecDagCBOR, raw)
				f.blocks[treeCID.String()] = car.Block{CID: treeCID, Data: raw}
				f.commit.Data = treeCID
				if err := f.commit.Sign(f.key); err != nil {
					t.Fatal(err)
				}
				f.replaceCommit(t)
			}
			result, err := f.reader().Read(context.Background(), snapshotFixtureDID, collections)
			if err == nil || len(result.Records) != 0 {
				t.Fatal("malformed snapshot accepted")
			}
		})
	}
}

func TestRepositorySnapshotResourceLimitsAndCancellation(t *testing.T) {
	for _, name := range []string{"bytes", "blocks", "requests", "records", "depth", "cancel", "rate exhaustion"} {
		t.Run(name, func(t *testing.T) {
			f := newSnapshotFixture(t, 73)
			reader := f.reader()
			ctx := context.Background()
			switch name {
			case "bytes":
				reader.MaximumBytes = 1
			case "blocks":
				reader.MaximumBlocks = 1
			case "requests":
				reader.MaximumRequests = 1
			case "records":
				reader.MaximumRecords = 1
			case "depth":
				reader.MaximumDepth = 1
			case "cancel":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			case "rate exhaustion":
				f.status = func(path string, n int) int { return 429 }
			}
			result, err := reader.Read(ctx, snapshotFixtureDID, []string{"site.standard.document"})
			if err == nil || len(result.Records) != 0 {
				t.Fatal("resource limit did not fail closed")
			}
			if name == "rate exhaustion" && f.calls["/"+snapshotFixtureDID] != 3 {
				t.Fatal("rate-limit retries unbounded")
			}
		})
	}
}
func TestRepositorySnapshotRateLimitRetryIsBoundedAndSucceeds(t *testing.T) {
	f := newSnapshotFixture(t, 2)
	f.status = func(path string, n int) int {
		if strings.HasSuffix(path, "getBlocks") && n == 1 {
			return 429
		}
		return 200
	}
	result, err := f.reader().Read(context.Background(), snapshotFixtureDID, []string{"site.standard.document"})
	if err != nil || len(result.Records) != 2 {
		t.Fatal("bounded retry did not recover", err)
	}
}

func TestRepositorySnapshotK256SigningKey(t *testing.T) {
	f := newSnapshotFixture(t, 2)
	key, err := crypto.GenerateK256()
	if err != nil {
		t.Fatal(err)
	}
	f.key = key
	f.document["verificationMethod"].([]any)[0].(map[string]any)["publicKeyMultibase"] = key.PublicKey().Multibase()
	if err := f.commit.Sign(key); err != nil {
		t.Fatal(err)
	}
	f.replaceCommit(t)
	result, err := f.reader().Read(context.Background(), snapshotFixtureDID, []string{"site.standard.document"})
	if err != nil || len(result.Records) != 2 {
		t.Fatal("secp256k1 signature verification failed", err)
	}
}

func TestRepositorySnapshotRejectsSigningKeyRotationDuringRead(t *testing.T) {
	f := newSnapshotFixture(t, 2)
	key, err := crypto.GenerateP256()
	if err != nil {
		t.Fatal(err)
	}
	f.mutate = func(path string, n int, body []byte) []byte {
		if path == "/"+snapshotFixtureDID && n == 2 {
			return bytes.ReplaceAll(body, []byte(f.key.PublicKey().Multibase()), []byte(key.PublicKey().Multibase()))
		}
		return body
	}
	result, err := f.reader().Read(context.Background(), snapshotFixtureDID, []string{"site.standard.document"})
	if err == nil || len(result.Records) != 0 {
		t.Fatal("snapshot accepted after signing key changed")
	}
}

func TestRepositorySnapshotRejectsSharedTreeBeforeRecursiveWalk(t *testing.T) {
	f := newSnapshotFixture(t, 1)
	// A shared empty subtree has no leaf callbacks of its own. It must be
	// rejected during bounded block discovery, not deferred to the final walk.
	empty, err := cbor.Marshal(map[string]any{"e": []any{}, "l": nil})
	if err != nil {
		t.Fatal(err)
	}
	emptyCID := cbor.ComputeCID(cbor.CodecDagCBOR, empty)
	f.blocks[emptyCID.String()] = car.Block{CID: emptyCID, Data: empty}
	value := cbor.ComputeCID(cbor.CodecDagCBOR, []byte("not fetched"))
	root, err := cbor.Marshal(map[string]any{"l": emptyCID, "e": []any{map[string]any{"p": int64(0), "k": []byte("site.standard.document/key000"), "v": value, "t": emptyCID}}})
	if err != nil {
		t.Fatal(err)
	}
	rootCID := cbor.ComputeCID(cbor.CodecDagCBOR, root)
	f.blocks[rootCID.String()] = car.Block{CID: rootCID, Data: root}
	f.commit.Data = rootCID
	if err := f.commit.Sign(f.key); err != nil {
		t.Fatal(err)
	}
	f.replaceCommit(t)
	result, err := f.reader().Read(context.Background(), snapshotFixtureDID, []string{"site.standard.document"})
	if err == nil || err.Error() != "repository snapshot repeated tree reference" || len(result.Records) != 0 {
		t.Fatal("shared tree was not rejected during discovery", err)
	}
	if f.requested[emptyCID.String()] || f.requested[value.String()] {
		t.Fatal("reader fetched descendants after discovering graph sharing")
	}
	if f.calls["/xrpc/com.atproto.sync.getBlocks"] != 2 {
		t.Fatal("shared tree caused extra block requests")
	}
}
