package semblecore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"net/url"
	"sync"
	"testing"
	"time"
)

type fakeTransport struct {
	body   string
	status int
	calls  int
	q      url.Values
}

func (f *fakeTransport) Get(ctx context.Context, path string, q url.Values) (int, []byte, error) {
	f.calls++
	f.q = q
	return f.status, []byte(f.body), nil
}

type fakeReader struct {
	read RecordRead
	err  error
}

func (f fakeReader) Read(context.Context, string, []string) (RecordRead, error) { return f.read, f.err }
func record(col, uri, raw string) Record {
	return Record{Collection: col, URI: uri, Value: json.RawMessage(raw)}
}

const connectionPage = `{"connections":[{"connection":{"id":"db-id","uri":"at://did:plc:viewer/network.cosmik.connection/spoof","type":"related","note":"a","curator":{"id":"did:plc:viewer"}},"source":{"url":"https://a.example"},"target":{"url":"https://b.example"}}],"pagination":{"currentPage":1,"hasMore":true}}`

func TestConnectionMutationRequiresExactPDSMatch(t *testing.T) {
	transport := &fakeTransport{body: connectionPage, status: 200}
	s := Service{transport, fakeReader{read: RecordRead{Complete: true}}}
	out, e := s.Connections(context.Background(), "did:plc:viewer", "https://a.example", nil, 50)
	if e != nil || len(out.Connections) != 1 || out.Connections[0].URI != nil || out.Connections[0].Editable || out.RecordLinksComplete {
		t.Fatalf("spoof accepted: %+v %v", out, e)
	}
	s.Reader = fakeReader{read: RecordRead{Complete: true, Records: []Record{record("network.cosmik.connection", "at://did:plc:other/network.cosmik.connection/a", `{"source":"https://a.example","target":"https://b.example","connectionType":"related","note":"a"}`), record("network.cosmik.connection", "at://did:plc:viewer/network.cosmik.connection/real", `{"source":"https://a.example","target":"https://b.example","connectionType":"related","note":"a"}`)}}}
	out, e = s.Connections(context.Background(), "did:plc:viewer", "https://a.example", nil, 50)
	if e != nil || !out.Connections[0].Editable || *out.Connections[0].URI != "at://did:plc:viewer/network.cosmik.connection/real" || !out.RecordLinksComplete {
		t.Fatalf("PDS match failed: %+v %v", out, e)
	}
	page, e := Page(out.Cursor)
	if e != nil || page != 2 || transport.q.Get("direction") != "both" {
		t.Fatal("pagination/query", page, e)
	}
}
func TestCollectionOwnerBeforeNetwork(t *testing.T) {
	f := &fakeTransport{}
	s := Service{Transport: f}
	_, e := s.Collection(context.Background(), "did:plc:viewer", "at://did:plc:other/network.cosmik.collection/a", nil, 50)
	if e != Forbidden || f.calls != 0 {
		t.Fatal(e, f.calls)
	}
}
func TestMissingRequiredUpstreamFieldsFailClosed(t *testing.T) {
	for _, body := range []string{`{"connections":[],"pagination":{"hasMore":false}}`, `{"connections":[],"pagination":{"currentPage":1}}`, `{"connections":[{"connection":{"id":"a","curator":{}},"source":{"url":"a"},"target":{"url":"b"}}],"pagination":{"currentPage":1,"hasMore":false}}`, `{"connections":null,"pagination":{"currentPage":1,"hasMore":false}}`} {
		s := Service{Transport: &fakeTransport{body: body, status: 200}}
		_, e := s.Connections(context.Background(), "did:plc:v", "https://a.example", nil, 50)
		var typed *Error
		if !errors.As(e, &typed) || typed.Status != 502 {
			t.Fatal(body, e)
		}
	}
}
func TestMembershipNotesAndIncompleteReads(t *testing.T) {
	body := `{"id":"c","uri":"at://did:plc:viewer/network.cosmik.collection/c","name":"N","cardCount":1,"author":{"id":"did:plc:viewer"},"urlCards":[{"id":"card","type":"URL","uri":"at://did:plc:viewer/network.cosmik.card/card","author":{"id":"did:plc:viewer"},"note":{"id":"note","text":"hello"},"cardContent":{"url":"https://a.example","imageUrl":"https://a.example/image"}}],"pagination":{"currentPage":1,"hasMore":false}}`
	s := Service{&fakeTransport{body: body, status: 200}, fakeReader{read: RecordRead{Complete: true, Records: []Record{record("network.cosmik.collectionLink", "at://did:plc:viewer/network.cosmik.collectionLink/l", `{"collection":{"uri":"at://did:plc:viewer/network.cosmik.collection/c"},"card":{"uri":"at://did:plc:viewer/network.cosmik.card/card"},"addedBy":"did:plc:viewer"}`), record("network.cosmik.card", "at://did:plc:viewer/network.cosmik.card/n", `{"type":"NOTE","parentCard":{"uri":"at://did:plc:viewer/network.cosmik.card/card"},"content":{"text":"hello"}}`)}}}}
	out, e := s.Collection(context.Background(), "did:plc:viewer", "at://did:plc:viewer/network.cosmik.collection/c", nil, 50)
	if e != nil || !out.MembershipComplete || !out.RecordLinksComplete || !out.Items[0].Note.Editable || !out.Items[0].Membership.ViewerOwned || out.Items[0].Image == nil {
		t.Fatalf("%+v %v", out, e)
	}
	s.Reader = fakeReader{err: errors.New("unavailable")}
	out, e = s.Collection(context.Background(), "did:plc:viewer", "at://did:plc:viewer/network.cosmik.collection/c", nil, 50)
	if e != nil || out.MembershipComplete || out.RecordLinksComplete || out.Items[0].UnlinkAvailable || out.Items[0].Note.Editable {
		t.Fatal(out, e)
	}
}

type blockingReader struct {
	mu          sync.Mutex
	active, max int
}

func (r *blockingReader) Read(ctx context.Context, _ string, _ []string) (RecordRead, error) {
	r.mu.Lock()
	r.active++
	if r.active > r.max {
		r.max = r.active
	}
	r.mu.Unlock()
	<-ctx.Done()
	r.mu.Lock()
	r.active--
	r.mu.Unlock()
	return RecordRead{}, ctx.Err()
}
func TestEnrichmentCancellationJoinsBoundedWorkers(t *testing.T) {
	r := &blockingReader{}
	s := Service{Reader: r}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	owners := map[string]bool{}
	for i := 0; i < 30; i++ {
		owners["did:plc:"+string(rune('a'+i))] = true
	}
	out := s.records(ctx, owners, []string{"a"})
	r.mu.Lock()
	defer r.mu.Unlock()
	if out.Complete || r.active != 0 || r.max > 8 {
		t.Fatal(out, r.active, r.max)
	}
}

type paginationRepo struct{ calls int }

func (r *paginationRepo) ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error) {
	r.calls++
	return gatewaycore.RepoPage{Cursor: "repeated"}, nil
}
func TestPublicReaderRepeatedCursorStopsIncomplete(t *testing.T) {
	r := &paginationRepo{}
	out, e := (PublicReader{r}).Read(context.Background(), "did:plc:v", []string{"a"})
	if e != nil || out.Complete || r.calls != 2 {
		t.Fatal(out, e, r.calls)
	}
}
func TestInvalidCursorAndURL(t *testing.T) {
	empty := ""
	if _, e := Page(&empty); e == nil {
		t.Fatal("empty cursor accepted")
	}
	s := Service{}
	if _, e := s.Connections(context.Background(), "did:plc:v", "file:///tmp/a", nil, 50); e == nil {
		t.Fatal("invalid url accepted")
	}
}
