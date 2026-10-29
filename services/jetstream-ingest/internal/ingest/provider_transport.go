package ingest

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sync"
)

var ErrLiveArchiveRequest = errors.New("live-only intake attempted an archive request")

type ProviderRejection struct{ Code, Message string }

type ProviderRejections struct {
	mu   sync.Mutex
	last ProviderRejection
}

func (p *ProviderRejections) Clear() { p.mu.Lock(); defer p.mu.Unlock(); p.last = ProviderRejection{} }
func (p *ProviderRejections) Snapshot() ProviderRejection {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.last
}

// Preserve the structured XRPC response while allowing the SDK to consume the
// identical body. An arbitrary transport/configuration error cannot reset a cursor.
type ProviderTransport struct {
	Base       http.RoundTripper
	Rejections *ProviderRejections
	LiveOnly   bool
}

func (t ProviderTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if t.LiveOnly && isArchiveRequest(request.URL.Path) {
		return nil, ErrLiveArchiveRequest
	}
	base := t.Base
	if base == nil {
		base = http.DefaultTransport
	}
	response, err := base.RoundTrip(request)
	if err != nil || response == nil || response.Body == nil || response.StatusCode != http.StatusBadRequest || t.Rejections == nil {
		return response, err
	}
	body, readErr := io.ReadAll(io.LimitReader(response.Body, 4096))
	response.Body = &prefixedReadCloser{Reader: io.MultiReader(bytes.NewReader(body), response.Body), Closer: response.Body}
	if readErr == nil {
		var envelope struct {
			Error   string `json:"error"`
			Message string `json:"message"`
		}
		if json.Unmarshal(body, &envelope) == nil && envelope.Error != "" {
			t.Rejections.mu.Lock()
			t.Rejections.last = ProviderRejection{Code: envelope.Error, Message: envelope.Message}
			t.Rejections.mu.Unlock()
		}
	}
	return response, nil
}

type prefixedReadCloser struct {
	io.Reader
	io.Closer
}
