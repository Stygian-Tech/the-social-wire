package semblecore

import (
	"context"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Transport interface {
	Get(context.Context, string, url.Values) (int, []byte, error)
}
type HTTPTransport struct {
	BaseURL string
	Client  *http.Client
}

func NewHTTPTransport(env map[string]string, client *http.Client) HTTPTransport {
	base := strings.TrimSpace(env["SEMBLE_PUBLIC_API_BASE_URL"])
	if base == "" {
		base = "https://api.semble.so/api"
	}
	if client == nil {
		client = gatewaycore.NewPublicHTTPClient(nil)
	}
	return HTTPTransport{strings.TrimRight(base, "/"), client}
}
func (t HTTPTransport) Get(ctx context.Context, path string, q url.Values) (int, []byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	r, e := http.NewRequestWithContext(ctx, "GET", t.BaseURL+path+"?"+q.Encode(), nil)
	if e != nil {
		return 0, nil, e
	}
	r.Header.Set("Accept", "application/json")
	resp, e := t.Client.Do(r)
	if e != nil {
		return 0, nil, e
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(io.LimitReader(resp.Body, (8<<20)+1))
	if len(b) > 8<<20 {
		return 0, nil, errors.New("Semble response exceeds bound")
	}
	return resp.StatusCode, b, e
}
