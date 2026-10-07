package thinappviewcore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type PDSRecordResponseError struct {
	Status int
	Code   string
}

func (e *PDSRecordResponseError) Error() string {
	return fmt.Sprintf("PDS record response %d %s", e.Status, e.Code)
}
func pdsRecordError(status int, body []byte) error {
	var response struct {
		Code string `json:"error"`
	}
	_ = json.Unmarshal(body, &response)
	code := ""
	if len(response.Code) <= 80 {
		safe := true
		for _, c := range response.Code {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
				safe = false
				break
			}
		}
		if safe {
			code = response.Code
		}
	}
	return &PDSRecordResponseError{Status: status, Code: code}
}

type PublicGetter interface {
	Get(context.Context, string, http.Header, int, int) (int, http.Header, []byte, error)
}
type PDSClient struct {
	HTTP          PublicGetter
	PLCBase       string
	mu            sync.Mutex
	endpoints     map[string]pdsEndpoint
	CacheTTL      time.Duration
	CacheCapacity int
	Now           func() time.Time
}

type pdsEndpoint struct {
	URL        string
	ExpiresAt  time.Time
	AccessedAt time.Time
}

func (p *PDSClient) Invalidate(did string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.endpoints, did)
}
func (p *PDSClient) Resolve(ctx context.Context, did string) (string, error) {
	if !strings.HasPrefix(did, "did:") {
		return "", errors.New("invalid DID")
	}
	p.mu.Lock()
	now := time.Now()
	if p.Now != nil {
		now = p.Now()
	}
	endpoint, cached := p.endpoints[did]
	if cached && endpoint.ExpiresAt.After(now) {
		endpoint.AccessedAt = now
		p.endpoints[did] = endpoint
	} else {
		delete(p.endpoints, did)
		cached = false
	}
	p.mu.Unlock()
	if cached {
		return endpoint.URL, nil
	}
	httpClient := p.HTTP
	if httpClient == nil {
		httpClient = PublicHTTP{}
	}
	root := p.PLCBase
	if root == "" {
		root = "https://plc.directory"
	}
	documentURL, err := didDocumentURL(did, root)
	if err != nil {
		return "", err
	}
	requestCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	status, _, body, err := httpClient.Get(requestCtx, documentURL, http.Header{"Accept": []string{"application/json"}}, 64*1024, 0)
	if err != nil {
		return "", err
	}
	if status == 429 || status >= 500 {
		return "", errors.New("PDS resolution transient status")
	}
	if status != 200 {
		return "", nil
	}
	var document struct {
		ID       string `json:"id"`
		Services []struct {
			ID       string `json:"id"`
			Type     string `json:"type"`
			Endpoint string `json:"serviceEndpoint"`
		} `json:"service"`
	}
	if err := json.Unmarshal(body, &document); err != nil {
		return "", errors.New("malformed DID document")
	}
	if document.ID != did {
		return "", errors.New("DID document identity mismatch")
	}
	matchingServices := 0
	for _, service := range document.Services {
		if service.Type == "AtprotoPersonalDataServer" {
			matchingServices++
		}
	}
	if matchingServices > 1 {
		return "", errors.New("ambiguous PDS services")
	}
	for _, service := range document.Services {
		if (service.ID == "#atproto_pds" || service.ID == did+"#atproto_pds") && service.Type == "AtprotoPersonalDataServer" {
			endpoint := ValidatePDSBase(service.Endpoint)
			if endpoint == "" {
				return "", errors.New("unsafe PDS service endpoint")
			}
			p.mu.Lock()
			if p.endpoints == nil {
				p.endpoints = map[string]pdsEndpoint{}
			}
			capacity := p.CacheCapacity
			if capacity <= 0 {
				capacity = 1024
			}
			if len(p.endpoints) >= capacity {
				var oldest string
				var access time.Time
				for key, value := range p.endpoints {
					if oldest == "" || value.AccessedAt.Before(access) {
						oldest = key
						access = value.AccessedAt
					}
				}
				delete(p.endpoints, oldest)
			}
			ttl := p.CacheTTL
			if ttl <= 0 {
				ttl = 5 * time.Minute
			}
			p.endpoints[did] = pdsEndpoint{URL: endpoint, ExpiresAt: now.Add(ttl), AccessedAt: now}
			p.mu.Unlock()
			return endpoint, nil
		}
	}
	return "", nil
}
func (p *PDSClient) FetchRecord(ctx context.Context, did, collection, key string, cid *string) (string, string, []byte, error) {
	base, err := p.Resolve(ctx, did)
	if err != nil {
		return "", "", nil, err
	}
	if base == "" {
		return "", "", nil, errors.New("PDS unavailable")
	}
	params := url.Values{"repo": []string{did}, "collection": []string{collection}, "rkey": []string{key}}
	if cid != nil {
		params.Set("cid", *cid)
	}
	httpClient := p.HTTP
	if httpClient == nil {
		httpClient = PublicHTTP{}
	}
	requestCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	status, _, body, err := httpClient.Get(requestCtx, base+"/xrpc/com.atproto.repo.getRecord?"+params.Encode(), http.Header{"Accept": []string{"application/json"}}, 65536+4096, 0)
	if err != nil {
		return "", "", nil, err
	}
	if status != 200 {
		return "", "", nil, pdsRecordError(status, body)
	}
	var record struct {
		URI   string          `json:"uri"`
		CID   string          `json:"cid"`
		Value json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(body, &record); err != nil {
		return "", "", nil, err
	}
	if record.URI != "at://"+did+"/"+collection+"/"+key || record.CID == "" || len(record.Value) == 0 || record.Value[0] != '{' {
		return "", "", nil, errors.New("PDS record envelope mismatch")
	}
	if cid != nil && record.CID != *cid {
		return "", "", nil, errors.New("PDS record CID mismatch")
	}
	return record.URI, record.CID, record.Value, nil
}

func didDocumentURL(did, plcRoot string) (string, error) {
	if strings.HasPrefix(did, "did:plc:") && len(strings.TrimPrefix(did, "did:plc:")) == 24 {
		for _, character := range strings.TrimPrefix(did, "did:plc:") {
			if !(character >= 'a' && character <= 'z' || character >= '2' && character <= '7') {
				return "", errors.New("invalid PLC DID")
			}
		}
		return strings.TrimRight(plcRoot, "/") + "/" + url.PathEscape(did), nil
	}
	if !strings.HasPrefix(did, "did:web:") {
		return "", errors.New("unsupported DID method")
	}
	segments := strings.Split(strings.TrimPrefix(did, "did:web:"), ":")
	host, err := url.PathUnescape(segments[0])
	if err != nil || host == "" {
		return "", errors.New("invalid did:web host")
	}
	base := ValidatePDSBase("https://" + host)
	if base == "" {
		return "", errors.New("unsafe did:web host")
	}
	if len(segments) == 1 {
		return base + "/.well-known/did.json", nil
	}
	path := make([]string, 0, len(segments)-1)
	for _, segment := range segments[1:] {
		decoded, err := url.PathUnescape(segment)
		if err != nil || decoded == "" || decoded == "." || decoded == ".." || strings.ContainsAny(decoded, "/\\?#") {
			return "", errors.New("invalid did:web path")
		}
		path = append(path, url.PathEscape(decoded))
	}
	return base + "/" + strings.Join(path, "/") + "/did.json", nil
}
