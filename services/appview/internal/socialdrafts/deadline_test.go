package socialdrafts

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialdraftcore"
)

type deadlineWriter struct {
	*httptest.ResponseRecorder
	mu                    sync.Mutex
	reads, writes         []time.Time
	attempted             int
	expired, entered      chan struct{}
	expireOnce, enterOnce sync.Once
	blockWrite            bool
	chunks                chan string
}

func newDeadlineWriter() *deadlineWriter {
	return &deadlineWriter{ResponseRecorder: httptest.NewRecorder(), expired: make(chan struct{}), entered: make(chan struct{})}
}
func (w *deadlineWriter) set(at time.Time, read bool) error {
	w.mu.Lock()
	if read {
		w.reads = append(w.reads, at)
	} else {
		w.writes = append(w.writes, at)
	}
	w.mu.Unlock()
	if !at.IsZero() && time.Until(at) < time.Second {
		w.expireOnce.Do(func() { close(w.expired) })
	}
	return nil
}
func (w *deadlineWriter) SetReadDeadline(at time.Time) error  { return w.set(at, true) }
func (w *deadlineWriter) SetWriteDeadline(at time.Time) error { return w.set(at, false) }
func (w *deadlineWriter) Write(b []byte) (int, error) {
	if w.blockWrite {
		w.mu.Lock()
		w.attempted = len(b)
		w.mu.Unlock()
		w.enterOnce.Do(func() { close(w.entered) })
		<-w.expired
		return 0, os.ErrDeadlineExceeded
	}
	n, err := w.ResponseRecorder.Write(b)
	if w.chunks != nil {
		w.chunks <- string(b[:n])
	}
	return n, err
}
func (w *deadlineWriter) expire() { w.expireOnce.Do(func() { close(w.expired) }) }

type blockedReadBody struct {
	expired, entered chan struct{}
	once             sync.Once
}

func (b *blockedReadBody) Read([]byte) (int, error) {
	b.once.Do(func() { close(b.entered) })
	<-b.expired
	return 0, os.ErrDeadlineExceeded
}
func (b *blockedReadBody) Close() error { return nil }

type observedTransferService struct {
	*fakeService
	upload   func(context.Context, io.Reader) (socialdraftcore.Asset, error)
	download func(context.Context) (io.ReadCloser, socialdraftcore.Asset, error)
	reserve  func(context.Context) (socialdraftcore.Asset, error)
	manifest func(context.Context) (socialdraftcore.Manifest, error)
}

func (s *observedTransferService) Upload(ctx context.Context, _ string, _ string, body io.Reader, _ int64) (socialdraftcore.Asset, error) {
	return s.upload(ctx, body)
}
func (s *observedTransferService) Download(ctx context.Context, _ string, _ string) (io.ReadCloser, socialdraftcore.Asset, error) {
	return s.download(ctx)
}
func (s *observedTransferService) Reserve(ctx context.Context, owner string, in socialdraftcore.ReserveInput) (socialdraftcore.Asset, error) {
	if s.reserve != nil {
		return s.reserve(ctx)
	}
	return s.fakeService.Reserve(ctx, owner, in)
}

func (s *observedTransferService) Manifest(ctx context.Context, owner, id string) (socialdraftcore.Manifest, error) {
	if s.manifest != nil {
		return s.manifest(ctx)
	}
	return s.fakeService.Manifest(ctx, owner, id)
}
func (s *observedTransferService) PutManifest(ctx context.Context, owner string, in socialdraftcore.PutManifestInput) (socialdraftcore.Manifest, error) {
	if s.manifest != nil {
		return s.manifest(ctx)
	}
	return s.fakeService.PutManifest(ctx, owner, in)
}

type observedReadCloser struct {
	io.ReadCloser
	closed chan struct{}
	once   sync.Once
}

func (r *observedReadCloser) Close() error {
	err := r.ReadCloser.Close()
	r.once.Do(func() { close(r.closed) })
	return err
}
func awaitIO(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(3 * time.Second):
		t.Fatal("private draft I/O did not finish")
	}
}
func checkBudget(t *testing.T, ctx context.Context, budget time.Duration) {
	t.Helper()
	deadline, ok := ctx.Deadline()
	if !ok || time.Until(deadline) > budget || time.Until(deadline) < budget-time.Second {
		t.Error("wrong private draft operation budget", deadline)
	}
}
func serveAsync(t *testing.T, handler http.Handler, w http.ResponseWriter, r *http.Request, abort bool) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer func() {
			p := recover()
			if abort && p != http.ErrAbortHandler {
				t.Errorf("stream failure did not abort: %v", p)
			} else if !abort && p != nil {
				t.Errorf("unexpected handler panic: %v", p)
			}
		}()
		handler.ServeHTTP(w, r)
	}()
	return done
}

func TestDirectAppViewUploadReadDeadlineAndCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	w := newDeadlineWriter()
	defer w.expire()
	body := &blockedReadBody{expired: w.expired, entered: make(chan struct{})}
	var operation context.Context
	s := &observedTransferService{fakeService: &fakeService{}, upload: func(ctx context.Context, r io.Reader) (socialdraftcore.Asset, error) {
		operation = ctx
		checkBudget(t, ctx, 2*time.Minute)
		_, err := io.ReadAll(r)
		return socialdraftcore.Asset{}, err
	}}
	mux := http.NewServeMux()
	Routes{Service: s}.Register(mux)
	r := request("POST", "uploadAttachment", "a", "did:plc:owner")
	r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
	r.Body = body
	r.Header.Set("Content-Type", "application/octet-stream")
	r.Header.Set("X-Social-Draft-Upload-Id", "a")
	done := serveAsync(t, mux, w, r, false)
	awaitIO(t, body.entered)
	w.mu.Lock()
	remaining := time.Until(w.reads[0])
	w.mu.Unlock()
	if remaining > 2*time.Minute || remaining < 2*time.Minute-time.Second {
		t.Fatal("upload read not bounded", remaining)
	}
	cancel()
	awaitIO(t, done)
	if operation.Err() != context.Canceled {
		t.Fatal("storage upload context not canceled", operation.Err())
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.reads[len(w.reads)-1].IsZero() || w.reads[len(w.reads)-1].After(time.Now()) {
		t.Fatal("canceled upload deadline must stay expired")
	}
}
func TestDirectAppViewJSONReadsHaveSixtySecondDeadline(t *testing.T) {
	for _, name := range []string{"reserveAttachment", "putManifest", "deleteManifest"} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			w := newDeadlineWriter()
			defer w.expire()
			body := &blockedReadBody{expired: w.expired, entered: make(chan struct{})}
			service := &fakeService{}
			mux := http.NewServeMux()
			Routes{Service: service}.Register(mux)
			r := request("POST", name, "{}", "did:plc:owner")
			r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
			r.Body = body
			done := serveAsync(t, mux, w, r, false)
			awaitIO(t, body.entered)
			w.mu.Lock()
			remaining := time.Until(w.reads[0])
			w.mu.Unlock()
			if remaining > time.Minute || remaining < time.Minute-time.Second {
				t.Fatal("JSON read not bounded to sixty seconds", remaining)
			}
			cancel()
			awaitIO(t, done)
			if service.owner != "" {
				t.Fatal("blocked JSON body entered storage")
			}
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.reads[len(w.reads)-1].IsZero() || w.reads[len(w.reads)-1].After(time.Now()) {
				t.Fatal("canceled JSON deadline must stay expired")
			}
		})
	}
}
func TestDirectAppViewJSONStorageContextIsBounded(t *testing.T) {
	s := &observedTransferService{fakeService: &fakeService{}, reserve: func(ctx context.Context) (socialdraftcore.Asset, error) {
		checkBudget(t, ctx, time.Minute)
		return socialdraftcore.Asset{}, nil
	}}
	mux := http.NewServeMux()
	Routes{Service: s}.Register(mux)
	r := request("POST", "reserveAttachment", `{"assetId":"a","name":"photo.jpg","contentType":"image/jpeg","byteLength":3,"sha256":"hash","kind":"photo"}`, "did:plc:owner")
	w := newDeadlineWriter()
	mux.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestDirectAppViewDownloadCancellationInterruptsWriterAndClosesReader(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	body := &observedReadCloser{ReadCloser: io.NopCloser(strings.NewReader("private bytes")), closed: make(chan struct{})}
	var operation context.Context
	s := &observedTransferService{fakeService: &fakeService{}, download: func(ctx context.Context) (io.ReadCloser, socialdraftcore.Asset, error) {
		operation = ctx
		checkBudget(t, ctx, 2*time.Minute)
		return body, socialdraftcore.Asset{ByteLength: 13, ContentType: "image/png"}, nil
	}}
	mux := http.NewServeMux()
	Routes{Service: s}.Register(mux)
	r := request("GET", "getAttachment?assetId=a", "", "did:plc:owner")
	r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
	w := newDeadlineWriter()
	w.blockWrite = true
	defer w.expire()
	done := serveAsync(t, mux, w, r, true)
	awaitIO(t, w.entered)
	select {
	case <-body.closed:
		t.Fatal("download reader closed before streaming ended")
	default:
	}
	cancel()
	awaitIO(t, done)
	awaitIO(t, body.closed)
	if operation.Err() != context.Canceled {
		t.Fatal("download storage context not canceled")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.writes) < 2 || w.writes[len(w.writes)-1].IsZero() || w.writes[len(w.writes)-1].After(time.Now()) {
		t.Fatal("canceled write deadline must stay expired", w.writes)
	}
}
func TestDirectAppViewDownloadStillStreamsBeforeEOF(t *testing.T) {
	reader, writer := io.Pipe()
	defer writer.Close()
	body := &observedReadCloser{ReadCloser: reader, closed: make(chan struct{})}
	s := &observedTransferService{fakeService: &fakeService{}, download: func(ctx context.Context) (io.ReadCloser, socialdraftcore.Asset, error) {
		checkBudget(t, ctx, 2*time.Minute)
		return body, socialdraftcore.Asset{ByteLength: 2, ContentType: "image/png"}, nil
	}}
	mux := http.NewServeMux()
	Routes{Service: s}.Register(mux)
	w := newDeadlineWriter()
	w.chunks = make(chan string, 4)
	done := serveAsync(t, mux, w, request("GET", "getAttachment?assetId=a", "", "did:plc:owner"), false)
	if _, err := writer.Write([]byte("a")); err != nil {
		t.Fatal(err)
	}
	select {
	case first := <-w.chunks:
		if first != "a" {
			t.Fatal(first)
		}
	case <-time.After(time.Second):
		t.Fatal("download buffered until EOF")
	}
	if _, err := writer.Write([]byte("b")); err != nil {
		t.Fatal(err)
	}
	writer.Close()
	awaitIO(t, done)
	awaitIO(t, body.closed)
	if w.Body.String() != "ab" {
		t.Fatal(w.Body.String())
	}
}

func TestDirectAppViewStalledJSONSocketCannotBlockCleanup(t *testing.T) {
	mux := http.NewServeMux()
	Routes{Service: &fakeService{}}.Register(mux)
	edge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 100*time.Millisecond)
		defer cancel()
		r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
		mux.ServeHTTP(w, r)
	}))
	defer edge.Close()
	conn, err := net.Dial("tcp", edge.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	io.WriteString(conn, "POST "+prefix+"putManifest HTTP/1.1\r\nHost: appview.invalid\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n")
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return
	}
	if err != nil {
		t.Fatal("direct AppView retained stalled JSON socket", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatal(resp.StatusCode)
	}
	if _, err = io.ReadAll(resp.Body); err != nil {
		t.Fatal("timeout response did not finish", err)
	}
}

func TestDisabledPrivateStorageStillBoundsMutationReads(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	w := newDeadlineWriter()
	mux.ServeHTTP(w, request("POST", "putManifest", "{}", "did:plc:owner"))
	if w.Code != 503 || len(w.reads) != 1 || time.Until(w.reads[0]) > time.Minute {
		t.Fatal("disabled private storage omitted read deadline", w.Code, w.reads)
	}
}

func TestDirectAppViewLargeManifestResponsesAreBounded(t *testing.T) {
	attachments := make([]socialdraftcore.AssetBinding, 800)
	for i := range attachments {
		attachments[i] = socialdraftcore.AssetBinding{AssetID: "a", Role: "original", Ref: "segment", Asset: socialdraftcore.Asset{AssetID: "a", Name: strings.Repeat("n", 256), ContentType: "image/jpeg", ByteLength: 1, Kind: "photo", State: "ready"}}
	}
	for _, tc := range []struct{ method, name, body string }{{"POST", "putManifest", `{"draftId":"d","expectedRevision":0,"attachments":[]}`}, {"GET", "getManifest?draftId=d", ""}} {
		t.Run(tc.method, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var operation context.Context
			s := &observedTransferService{fakeService: &fakeService{}, manifest: func(ctx context.Context) (socialdraftcore.Manifest, error) {
				operation = ctx
				checkBudget(t, ctx, time.Minute)
				return socialdraftcore.Manifest{DraftID: "d", Revision: 1, Attachments: attachments}, nil
			}}
			mux := http.NewServeMux()
			Routes{Service: s}.Register(mux)
			r := request(tc.method, tc.name, tc.body, "did:plc:owner")
			r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
			w := newDeadlineWriter()
			w.blockWrite = true
			defer w.expire()
			done := serveAsync(t, mux, w, r, false)
			awaitIO(t, w.entered)
			w.mu.Lock()
			remaining := time.Until(w.writes[0])
			w.mu.Unlock()
			if remaining > time.Minute || remaining < time.Minute-time.Second {
				t.Fatal("manifest write deadline not sixty seconds", remaining)
			}
			cancel()
			awaitIO(t, done)
			if operation.Err() != context.Canceled {
				t.Fatal("manifest service context not canceled")
			}
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.attempted < 64<<10 || len(w.writes) < 2 || w.writes[len(w.writes)-1].After(time.Now()) {
				t.Fatal("large manifest output not interrupted", w.attempted, w.writes)
			}
			if tc.method == "POST" && (len(w.reads) < 2 || w.reads[len(w.reads)-1].After(time.Now())) {
				t.Fatal("POST cancellation did not expire read deadline", w.reads)
			}
			if tc.method == "GET" && len(w.reads) != 0 {
				t.Fatal("GET unexpectedly installed a read deadline")
			}
		})
	}
}
