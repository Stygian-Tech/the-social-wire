package podcasts

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

var ErrSourceUnavailable = errors.New("podcast source unavailable")

func pointer[T any](v T) *T { return &v }

type FetchOptions struct {
	MaximumBytes     int
	Timeout          time.Duration
	ValidateURL      func(string) bool
	Headers          http.Header
	ContentType      string
	AllowPartial     bool
	MaximumRedirects *int
}
type MediaFetcher struct{ Client *http.Client }

func (f MediaFetcher) client() *http.Client {
	client := f.Client
	if client == nil {
		client = gatewaycore.NewPublicHTTPClient(nil)
	}
	copy := *client
	copy.Timeout = 0
	copy.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &copy
}
func redirect(status int) bool {
	return status == 301 || status == 302 || status == 303 || status == 307 || status == 308
}
func nextURL(current, location string) (string, error) {
	base, err := url.Parse(current)
	if err != nil {
		return "", ErrSourceUnavailable
	}
	next, err := url.Parse(location)
	if err != nil {
		return "", ErrSourceUnavailable
	}
	return base.ResolveReference(next).String(), nil
}
func (f MediaFetcher) Fetch(ctx context.Context, raw string, options FetchOptions) ([]byte, error) {
	timeout := options.Timeout
	if timeout <= 0 {
		timeout = 25 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	maximumRedirects := 5
	if options.MaximumRedirects != nil {
		maximumRedirects = *options.MaximumRedirects
	}
	if maximumRedirects < 0 || maximumRedirects > 10 || options.MaximumBytes < 0 {
		return nil, ErrSourceUnavailable
	}
	current := raw
	client := f.client()
	for hop := 0; hop <= maximumRedirects; hop++ {
		if !podcastcore.PrivateURLAllowed(current) || options.ValidateURL != nil && !options.ValidateURL(current) {
			return nil, ErrSourceUnavailable
		}
		request, err := http.NewRequestWithContext(ctx, "GET", current, nil)
		if err != nil {
			return nil, ErrSourceUnavailable
		}
		request.Header = options.Headers.Clone()
		response, err := client.Do(request)
		if err != nil {
			return nil, ErrSourceUnavailable
		}
		if redirect(response.StatusCode) && response.Header.Get("Location") != "" {
			response.Body.Close()
			if hop == maximumRedirects {
				return nil, ErrSourceUnavailable
			}
			current, err = nextURL(current, response.Header.Get("Location"))
			if err != nil {
				return nil, err
			}
			continue
		}
		if response.StatusCode != 200 && !(options.AllowPartial && response.StatusCode == 206) {
			response.Body.Close()
			return nil, ErrSourceUnavailable
		}
		if options.ContentType != "" && !strings.EqualFold(strings.TrimSpace(strings.Split(response.Header.Get("Content-Type"), ";")[0]), options.ContentType) {
			response.Body.Close()
			return nil, ErrSourceUnavailable
		}
		data, err := io.ReadAll(io.LimitReader(response.Body, int64(options.MaximumBytes)+1))
		response.Body.Close()
		if err != nil || len(data) > options.MaximumBytes || ctx.Err() != nil {
			return nil, ErrSourceUnavailable
		}
		return data, nil
	}
	return nil, ErrSourceUnavailable
}
func (f MediaFetcher) Fingerprint(ctx context.Context, raw string) (*string, error) {
	current := raw
	client := f.client()
	for hop := 0; hop < 6; hop++ {
		if !podcastcore.PrivateURLAllowed(current) {
			return nil, ErrSourceUnavailable
		}
		hopCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		request, err := http.NewRequestWithContext(hopCtx, "HEAD", current, nil)
		if err != nil {
			cancel()
			return nil, ErrSourceUnavailable
		}
		response, err := client.Do(request)
		if err != nil {
			cancel()
			return nil, ErrSourceUnavailable
		}
		response.Body.Close()
		cancel()
		if redirect(response.StatusCode) && response.Header.Get("Location") != "" {
			current, err = nextURL(current, response.Header.Get("Location"))
			if err != nil {
				return nil, err
			}
			continue
		}
		etag, modified := response.Header.Get("ETag"), response.Header.Get("Last-Modified")
		if response.StatusCode != 200 || etag == "" && modified == "" {
			return nil, nil
		}
		value := strings.Join([]string{raw, etag, modified, response.Header.Get("Content-Length")}, "|")
		return &value, nil
	}
	return nil, nil
}
