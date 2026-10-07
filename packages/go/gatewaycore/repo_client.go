package gatewaycore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

type PDSHTTPError struct {
	Status  int
	Nonce   string
	Message string
}

func (e PDSHTTPError) Error() string { return e.Message }

type RepoRecord struct {
	RawJSON json.RawMessage            `json:"-"`
	URI     string                     `json:"uri"`
	CID     string                     `json:"cid,omitempty"`
	Value   map[string]json.RawMessage `json:"value"`
}
type RepoPage struct {
	Records []RepoRecord `json:"records"`
	Cursor  string       `json:"cursor,omitempty"`
}
type RepoClient struct {
	Client *http.Client
	PLCURL string
	// PDSResolver is an optional acceleration boundary; callers retain the same read validation.
	PDSResolver func(context.Context, string) (string, error)
}

func (c *RepoClient) ResolveDID(ctx context.Context, repo string) (string, error) {
	if strings.HasPrefix(repo, "did:") {
		return repo, nil
	}
	v := TokenVerifier{Client: c.Client}
	body, status, e := v.fetch(ctx, "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle="+url.QueryEscape(repo), 65536)
	if e != nil {
		return "", e
	}
	if status != 200 {
		return "", ErrAuthentication
	}
	var doc struct {
		DID string `json:"did"`
	}
	if json.Unmarshal(body, &doc) != nil || !strings.HasPrefix(doc.DID, "did:") {
		return "", ErrAuthentication
	}
	return doc.DID, nil
}

// WithPDSResolver returns an independent client configuration without changing transport ownership.
func (c *RepoClient) WithPDSResolver(resolve func(context.Context, string) (string, error)) *RepoClient {
	clone := *c
	clone.PDSResolver = resolve
	return &clone
}
func (c *RepoClient) ResolvePDS(ctx context.Context, did string) (string, error) {
	if c.PDSResolver != nil {
		endpoint, err := c.PDSResolver(ctx, did)
		if err != nil {
			return "", err
		}
		return NormalizePublicRemoteBase(endpoint)
	}

	v := TokenVerifier{Client: c.Client}
	raw, status, e := v.fetch(ctx, strings.TrimRight(c.PLCURL, "/")+"/"+url.PathEscape(did), 262144)
	if e != nil {
		return "", e
	}
	if status == 429 || status >= 500 {
		return "", PDSHTTPError{Status: status, Message: "PDS resolution is unavailable"}
	}
	if status != 200 {
		return "", ErrAuthentication
	}
	var doc struct {
		Service []struct{ ID, Type, ServiceEndpoint string }
	}
	if json.Unmarshal(raw, &doc) != nil {
		return "", ErrAuthentication
	}
	for _, s := range doc.Service {
		if s.ID == "#atproto_pds" || s.Type == "AtprotoPersonalDataServer" {
			return NormalizePublicRemoteBase(s.ServiceEndpoint)
		}
	}
	return "", ErrAuthentication
}
func (c *RepoClient) publicJSON(ctx context.Context, target string, maximum int, out any) error {
	v := TokenVerifier{Client: c.Client}
	raw, status, e := v.fetch(ctx, target, maximum)
	if e != nil {
		return e
	}
	if status == 404 || status == 400 {
		return PDSHTTPError{404, "", "PDS record not found"}
	}
	if status != 200 {
		return PDSHTTPError{502, "", "PDS public request failed"}
	}
	if json.Unmarshal(raw, out) != nil {
		return PDSHTTPError{502, "", "PDS public response malformed"}
	}
	return nil
}

// Public records are fetched without OAuth credentials or ingress DPoP proofs.
func (c *RepoClient) GetRecord(ctx context.Context, repo, collection, rkey, cid string) (*RepoRecord, error) {
	did, e := c.ResolveDID(ctx, repo)
	if e != nil {
		return nil, e
	}
	base, e := c.ResolvePDS(ctx, did)
	if e != nil {
		return nil, e
	}
	q := url.Values{"repo": {did}, "collection": {collection}, "rkey": {rkey}}
	if cid != "" {
		q.Set("cid", cid)
	}
	var record RepoRecord
	var raw json.RawMessage
	e = c.publicJSON(ctx, base+"/xrpc/com.atproto.repo.getRecord?"+q.Encode(), 1048576, &raw)
	if e != nil {
		var pds PDSHTTPError
		if errors.As(e, &pds) && pds.Status == 404 {
			return nil, nil
		}
		return nil, e
	}
	if json.Unmarshal(raw, &record) != nil {
		return nil, PDSHTTPError{502, "", "PDS public response malformed"}
	}
	record.RawJSON = raw
	if record.Value == nil {
		return nil, nil
	}
	if record.URI != "" && record.URI != "at://"+did+"/"+collection+"/"+rkey {
		return nil, ErrAuthentication
	}
	if cid != "" && record.CID != cid {
		return nil, ErrAuthentication
	}
	return &record, nil
}
func (c *RepoClient) ListRecords(ctx context.Context, repo, collection, cursor string, limit int, reverse bool) (RepoPage, error) {
	did, e := c.ResolveDID(ctx, repo)
	if e != nil {
		return RepoPage{}, e
	}
	base, e := c.ResolvePDS(ctx, did)
	if e != nil {
		return RepoPage{}, e
	}
	u, _ := url.Parse(base)
	relay := u.Hostname() == "atproto.brid.gy" || strings.HasSuffix(u.Hostname(), ".brid.gy")
	q := url.Values{"repo": {did}, "collection": {collection}, "limit": {jsonNumber(max(1, min(limit, 100)))}, "reverse": {"false"}}
	if reverse && !relay {
		q.Set("reverse", "true")
	}
	if cursor != "" {
		q.Set("cursor", cursor)
	}
	var page RepoPage
	e = c.publicJSON(ctx, base+"/xrpc/com.atproto.repo.listRecords?"+q.Encode(), 1048576, &page)
	if e != nil {
		var pds PDSHTTPError
		if errors.As(e, &pds) && pds.Status == 404 {
			return RepoPage{Records: []RepoRecord{}}, nil
		}
		return RepoPage{}, e
	}
	if page.Records == nil {
		return RepoPage{}, PDSHTTPError{502, "", "Malformed PDS records page"}
	}
	for _, r := range page.Records {
		if r.URI == "" || r.Value == nil {
			return RepoPage{}, PDSHTTPError{502, "", "Malformed PDS records row"}
		}
	}
	if reverse && relay {
		sort.SliceStable(page.Records, func(i, j int) bool {
			date := func(r RepoRecord) string {
				for _, k := range []string{"publishedAt", "createdAt", "indexedAt"} {
					var s string
					if json.Unmarshal(r.Value[k], &s) == nil && s != "" {
						return s
					}
				}
				return ""
			}
			a, b := date(page.Records[i]), date(page.Records[j])
			if a != b {
				return a > b
			}
			return page.Records[i].URI > page.Records[j].URI
		})
	}
	return page, nil
}
func jsonNumber(n int) string { b, _ := json.Marshal(n); return string(b) }
func (c *RepoClient) Mutate(ctx context.Context, auth AuthContext, method string, body map[string]any) (map[string]json.RawMessage, error) {
	if method != "com.atproto.repo.putRecord" && method != "com.atproto.repo.deleteRecord" && method != "com.atproto.repo.createRecord" {
		return nil, ErrAuthentication
	}
	base, e := c.ResolvePDS(ctx, auth.DID)
	if e != nil {
		return nil, e
	}
	target := base + "/xrpc/" + method
	proof := auth.UpstreamDPoP
	if proof == "" {
		proof = auth.DPoP
	}
	parts := strings.Fields(auth.Authorization)
	if len(parts) != 2 || (!strings.EqualFold(parts[0], "DPoP") && !strings.EqualFold(parts[0], "Bearer")) {
		return nil, ErrAuthentication
	}
	token := parts[1]
	candidate, e := DecodeAccessCandidate(token, time.Now())
	if e != nil {
		return nil, e
	}
	if _, e = VerifyDPoP(proof, "POST", target, token, candidate.JKT, time.Now()); e != nil {
		return nil, PDSHTTPError{401, "", "PDS-bound upstream DPoP is required"}
	}
	body["repo"] = auth.DID
	raw, e := json.Marshal(body)
	if e != nil {
		return nil, e
	}
	work, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	r, e := http.NewRequestWithContext(work, "POST", target, bytes.NewReader(raw))
	if e != nil {
		return nil, e
	}
	r.Header.Set("Accept", "application/json")
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("Authorization", auth.Authorization)
	r.Header.Set("DPoP", proof)
	resp, e := c.Client.Do(r)
	if e != nil {
		return nil, ErrAuthDependency
	}
	defer resp.Body.Close()
	data, e := io.ReadAll(io.LimitReader(resp.Body, 1048577))
	if e != nil {
		return nil, ErrAuthDependency
	}
	if len(data) > 1048576 {
		return nil, PDSHTTPError{502, "", "PDS response exceeded limit"}
	}
	if resp.StatusCode != 200 {
		status := 502
		if resp.StatusCode == 401 || resp.StatusCode == 403 {
			status = resp.StatusCode
		}
		return nil, PDSHTTPError{status, resp.Header.Get("DPoP-Nonce"), "PDS mutation rejected"}
	}
	var result map[string]json.RawMessage
	if json.Unmarshal(data, &result) != nil {
		return nil, PDSHTTPError{502, "", "PDS mutation response malformed"}
	}
	return result, nil
}
