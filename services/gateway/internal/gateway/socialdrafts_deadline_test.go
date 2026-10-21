package gateway

import (
	"bufio"
	"context"
	"encoding/json"
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
)

type stalledDraftWriter struct {
	*httptest.ResponseRecorder
	mu                    sync.Mutex
	readAt, writeAt       []time.Time
	attempted             int
	expired, entered      chan struct{}
	expireOnce, enterOnce sync.Once
}

func newStalledDraftWriter() *stalledDraftWriter {
	return &stalledDraftWriter{ResponseRecorder: httptest.NewRecorder(), expired: make(chan struct{}), entered: make(chan struct{})}
}
func (w *stalledDraftWriter) set(at time.Time, read bool) error {
	w.mu.Lock()
	if read {
		w.readAt = append(w.readAt, at)
	} else {
		w.writeAt = append(w.writeAt, at)
	}
	w.mu.Unlock()
	if !at.IsZero() && time.Until(at) < time.Second {
		w.expireOnce.Do(func() { close(w.expired) })
	}
	return nil
}
func (w *stalledDraftWriter) SetWriteDeadline(at time.Time) error { return w.set(at, false) }
func (w *stalledDraftWriter) SetReadDeadline(at time.Time) error  { return w.set(at, true) }
func (w *stalledDraftWriter) Write(b []byte) (int, error) {
	w.mu.Lock()
	w.attempted = len(b)
	w.mu.Unlock()
	w.enterOnce.Do(func() { close(w.entered) })
	<-w.expired
	return 0, os.ErrDeadlineExceeded
}
func (w *stalledDraftWriter) expire() { w.expireOnce.Do(func() { close(w.expired) }) }

type closeTrackedDraftBody struct {
	io.Reader
	closed chan struct{}
	once   sync.Once
}

func (b *closeTrackedDraftBody) Close() error { b.once.Do(func() { close(b.closed) }); return nil }
func awaitDraftSignal(t *testing.T, signal <-chan struct{}) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(3 * time.Second):
		t.Fatal("private draft I/O did not finish")
	}
}

func TestSocialDraftDownloadCancellationInterruptsBlockedWriterAndReleasesSlot(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	body := &closeTrackedDraftBody{Reader: strings.NewReader("private bytes"), closed: make(chan struct{})}
	p := Proxy{Config: Config{AppViewURL: "https://appview.invalid"}, Internal: &http.Client{Transport: contractTransport(func(r *http.Request) (*http.Response, error) {
		deadline, ok := r.Context().Deadline()
		if !ok || time.Until(deadline) > 2*time.Minute || time.Until(deadline) < 2*time.Minute-time.Second {
			t.Error("download context not bounded to two minutes")
		}
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"image/png"}}, Body: body}, nil
	})}}
	a := &socialDraftAdmission{}
	handler := a.middleware(p.Handler(draftRoute("getAttachment")))
	r := httptest.NewRequest("GET", draftPrefix+"getAttachment?assetId=a", nil)
	r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
	w := newStalledDraftWriter()
	defer w.expire()
	done := make(chan struct{})
	go func() { defer close(done); handler.ServeHTTP(w, r) }()
	awaitDraftSignal(t, w.entered)
	a.mu.Lock()
	active := a.active
	a.mu.Unlock()
	if active != 1 {
		t.Fatal("download did not retain transfer admission", active)
	}
	cancel()
	awaitDraftSignal(t, done)
	awaitDraftSignal(t, body.closed)
	a.mu.Lock()
	active = a.active
	a.mu.Unlock()
	if active != 0 {
		t.Fatal("canceled download retained transfer slot", active)
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.writeAt) < 2 || w.writeAt[0].IsZero() || w.writeAt[len(w.writeAt)-1].IsZero() || w.writeAt[len(w.writeAt)-1].After(time.Now()) {
		t.Fatal("write deadline not installed/expired on cancellation", w.writeAt)
	}
}

type stalledDraftReadBody struct {
	expired, entered chan struct{}
	once             sync.Once
}

func (b *stalledDraftReadBody) Read([]byte) (int, error) {
	b.once.Do(func() { close(b.entered) })
	<-b.expired
	return 0, os.ErrDeadlineExceeded
}
func (b *stalledDraftReadBody) Close() error { return nil }
func TestSocialDraftJSONBodyReadHasDeadlineAndCancellationBeforeUpstream(t *testing.T) {
	for _, name := range []string{"reserveAttachment", "putManifest", "deleteManifest"} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			w := newStalledDraftWriter()
			defer w.expire()
			// JSON error output must not itself block this body-read test.
			rw := &draftReadOnlyDeadlineWriter{stalledDraftWriter: w}
			body := &stalledDraftReadBody{expired: w.expired, entered: make(chan struct{})}
			r := draftRequest(name, body)
			r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
			p := Proxy{Config: Config{AppViewURL: "https://appview.invalid"}, Internal: &http.Client{Transport: contractTransport(func(*http.Request) (*http.Response, error) {
				t.Error("stalled JSON body reached upstream")
				return nil, os.ErrDeadlineExceeded
			})}}
			done := make(chan struct{})
			go func() { defer close(done); p.Handler(draftRoute(name)).ServeHTTP(rw, r) }()
			awaitDraftSignal(t, body.entered)
			w.mu.Lock()
			remaining := time.Until(w.readAt[0])
			w.mu.Unlock()
			if remaining > time.Minute || remaining < time.Minute-time.Second {
				t.Fatal("JSON read deadline not sixty seconds", remaining)
			}
			cancel()
			awaitDraftSignal(t, done)
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.readAt[len(w.readAt)-1].IsZero() || w.readAt[len(w.readAt)-1].After(time.Now()) {
				t.Fatal("canceled read deadline must stay expired")
			}
		})
	}
}

type draftReadOnlyDeadlineWriter struct{ *stalledDraftWriter }

func (w *draftReadOnlyDeadlineWriter) Write(b []byte) (int, error) {
	return w.ResponseRecorder.Write(b)
}

func TestSocialDraftDownloadRealSocketDeadlinePreservesStreaming(t *testing.T) {
	body := &closeTrackedDraftBody{Reader: io.LimitReader(draftZeroReader{}, 64<<20), closed: make(chan struct{})}
	p := Proxy{Config: Config{AppViewURL: "https://appview.invalid"}, Internal: &http.Client{Transport: contractTransport(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"image/png"}}, Body: body}, nil
	})}}
	a := &socialDraftAdmission{}
	handler := a.middleware(p.Handler(draftRoute("getAttachment")))
	done := make(chan struct{})
	edge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(done)
		ctx, cancel := context.WithTimeout(r.Context(), 100*time.Millisecond)
		defer cancel()
		r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
		handler.ServeHTTP(w, r)
	}))
	defer edge.Close()
	res, err := edge.Client().Get(edge.URL + "?assetId=a")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	// Receiving the first byte while the rest is blocked proves unbuffered output.
	first := make([]byte, 1)
	if _, err = io.ReadFull(res.Body, first); err != nil {
		t.Fatal(err)
	}
	awaitDraftSignal(t, done)
	awaitDraftSignal(t, body.closed)
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.active != 0 {
		t.Fatal("slow socket retained transfer slot", a.active)
	}
}

type draftZeroReader struct{}

func (draftZeroReader) Read(b []byte) (int, error) { clear(b); return len(b), nil }

func TestSocialDraftStalledJSONSocketCannotBlockHandlerCleanup(t *testing.T) {
	p := Proxy{Config: Config{AppViewURL: "https://appview.invalid"}, Internal: &http.Client{Transport: contractTransport(func(*http.Request) (*http.Response, error) {
		t.Error("incomplete body reached upstream")
		return nil, os.ErrDeadlineExceeded
	})}}
	edge := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 100*time.Millisecond)
		defer cancel()
		r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
		p.Handler(draftRoute("putManifest")).ServeHTTP(w, r)
	}))
	defer edge.Close()
	conn, err := net.Dial("tcp", edge.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	// Advertise a small body and then never send it. The handler and net/http's
	// post-handler drain must both retain the socket deadline.
	io.WriteString(conn, "POST "+draftPrefix+"putManifest HTTP/1.1\r\nHost: gateway.invalid\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n")
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return
	}
	if err != nil {
		t.Fatal("stalled JSON socket retained handler", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 413 {
		t.Fatal(resp.StatusCode)
	}
	if _, err = io.ReadAll(resp.Body); err != nil {
		t.Fatal("timeout response did not finish", err)
	}
}

func TestSocialDraftUnavailableUpstreamStillBoundsJSONBody(t *testing.T) {
	p := Proxy{}
	w := newStalledDraftWriter()
	rw := &draftReadOnlyDeadlineWriter{stalledDraftWriter: w}
	p.Handler(draftRoute("putManifest")).ServeHTTP(rw, draftRequest("putManifest", strings.NewReader("{}")))
	if w.Code != 503 || len(w.readAt) != 1 || time.Until(w.readAt[0]) > time.Minute {
		t.Fatal("unconfigured private route omitted read deadline", w.Code, w.readAt)
	}
}

func TestSocialDraftLargeManifestResponsesHaveWriteDeadlineAndCancellation(t *testing.T) {
	attachments := make([]map[string]string, 800)
	for i := range attachments {
		attachments[i] = map[string]string{"assetId": "a", "role": "original", "ref": strings.Repeat("r", 256)}
	}
	payload, _ := json.Marshal(map[string]any{"draftId": "d", "revision": 1, "deleted": false, "attachments": attachments})
	for _, tc := range []struct{ method, name string }{{"POST", "putManifest"}, {"GET", "getManifest"}} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			body := &closeTrackedDraftBody{Reader: strings.NewReader(string(payload)), closed: make(chan struct{})}
			var upstream context.Context
			p := Proxy{Config: Config{AppViewURL: "https://appview.invalid"}, Internal: &http.Client{Transport: contractTransport(func(r *http.Request) (*http.Response, error) {
				upstream = r.Context()
				deadline, ok := upstream.Deadline()
				if !ok || time.Until(deadline) > time.Minute || time.Until(deadline) < time.Minute-time.Second {
					t.Error("manifest context not bounded to sixty seconds")
				}
				return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: body}, nil
			})}}
			r := httptest.NewRequest(tc.method, draftPrefix+tc.name, strings.NewReader(`{"draftId":"d","expectedRevision":0,"attachments":[]}`))
			r = r.WithContext(gatewaycore.ContextWithAuth(ctx, gatewaycore.AuthContext{DID: "did:plc:owner"}))
			w := newStalledDraftWriter()
			defer w.expire()
			done := make(chan struct{})
			go func() { defer close(done); p.Handler(draftRoute(tc.name)).ServeHTTP(w, r) }()
			awaitDraftSignal(t, w.entered)
			w.mu.Lock()
			remaining := time.Until(w.writeAt[0])
			w.mu.Unlock()
			if remaining > time.Minute || remaining < time.Minute-time.Second {
				t.Fatal("manifest write deadline not sixty seconds", remaining)
			}
			cancel()
			awaitDraftSignal(t, done)
			awaitDraftSignal(t, body.closed)
			if upstream.Err() != context.Canceled {
				t.Fatal("upstream manifest context not canceled")
			}
			w.mu.Lock()
			defer w.mu.Unlock()
			if w.attempted < 64<<10 || len(w.writeAt) < 2 || w.writeAt[len(w.writeAt)-1].After(time.Now()) {
				t.Fatal("large manifest output not interrupted", w.attempted, w.writeAt)
			}
			if tc.method == "POST" && (len(w.readAt) < 2 || w.readAt[len(w.readAt)-1].After(time.Now())) {
				t.Fatal("POST cancellation did not expire read deadline", w.readAt)
			}
			if tc.method == "GET" && len(w.readAt) != 0 {
				t.Fatal("GET unexpectedly installed a read deadline")
			}
		})
	}
}
