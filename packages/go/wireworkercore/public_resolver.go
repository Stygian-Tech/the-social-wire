package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type PublicResolver struct {
	DB     *sql.DB
	PDS    *thinappviewcore.PDSClient
	DNS    *gatewaycore.PublicDNSValidator
	mu     sync.Mutex
	misses map[string]time.Time
}

func NewPublicResolver(db *sql.DB, pds *thinappviewcore.PDSClient) *PublicResolver {
	return &PublicResolver{DB: db, PDS: pds, DNS: gatewaycore.NewPublicDNSValidator(nil, 64), misses: map[string]time.Time{}}
}
func (p *PublicResolver) Invalidate(uri string) { p.mu.Lock(); delete(p.misses, uri); p.mu.Unlock() }
func (p *PublicResolver) InvalidateAccount(did string) {
	p.mu.Lock()
	for uri := range p.misses {
		if ref := ParsePublicationReference(uri); ref != nil && ref.RepoDID == did {
			delete(p.misses, uri)
		}
	}
	p.mu.Unlock()
	p.PDS.Invalidate(did)
}
func (p *PublicResolver) load(ctx context.Context, uri string, at time.Time) (*PublicationMetadata, error) {
	var metadata PublicationMetadata
	err := p.DB.QueryRowContext(ctx, `SELECT publication_uri,repo_did,site_url,name FROM wire_publications WHERE publication_uri=$1 AND expires_at>$2 LIMIT 1`, uri, at).Scan(&metadata.URI, &metadata.RepoDID, &metadata.SiteURL, &metadata.Name)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &metadata, nil
}
func (p *PublicResolver) Resolve(ctx context.Context, uri string, at time.Time) (*PublicationMetadata, error) {
	ref := ParsePublicationReference(uri)
	if ref == nil {
		return nil, ErrMalformedDocument
	}
	// Always consult durable state first so a local miss cannot hide another
	// replica's publication event.
	metadata, err := p.load(ctx, ref.URI, at)
	if err != nil || metadata != nil {
		return metadata, err
	}
	p.mu.Lock()
	missed := p.misses[ref.URI].After(at)
	p.mu.Unlock()
	if missed {
		return nil, nil
	}
	requestCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	returnedURI, _, data, err := p.PDS.FetchRecord(requestCtx, ref.RepoDID, ref.Collection, ref.RecordKey, nil)
	if err != nil {
		var response *thinappviewcore.PDSRecordResponseError
		if errors.As(err, &response) && (response.Status == 404 || response.Status == 400 && response.Code == "RecordNotFound") {
			p.rememberMiss(ref.URI, at)
			return nil, nil
		}
		return nil, err
	}
	if len(data) == 0 {
		p.rememberMiss(ref.URI, at)
		return nil, nil
	}
	if returnedURI != ref.URI {
		return nil, errors.New("publication identity mismatch")
	}
	var record map[string]any
	if json.Unmarshal(data, &record) != nil {
		return nil, errors.New("invalid publication response")
	}
	metadata = ParsePublicationMetadata(ref.URI, ref.RepoDID, record)
	if metadata == nil {
		return nil, errors.New("invalid publication metadata")
	}
	tx, err := p.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if err := SavePublicationMetadata(ctx, tx, *metadata, at, false); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	p.Invalidate(ref.URI)
	// A newer event may win the durable fence. Return only the accepted row.
	return p.load(ctx, ref.URI, at)
}
func (p *PublicResolver) rememberMiss(uri string, at time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if len(p.misses) >= 512 {
		clear(p.misses)
	}
	p.misses[uri] = at.Add(600 * time.Second)
}
func (p *PublicResolver) ResolveBlobURL(ctx context.Context, did, cid string) (string, error) {
	cid = strings.TrimSpace(cid)
	if cid == "" || len(cid) > 512 {
		return "", nil
	}
	base, err := p.PDS.Resolve(ctx, did)
	if err != nil || base == "" {
		return "", err
	}
	parsed, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	if host := strings.ToLower(parsed.Hostname()); host == "atproto.brid.gy" || strings.HasSuffix(host, ".brid.gy") {
		return "", nil
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/xrpc/com.atproto.sync.getBlob"
	parsed.RawQuery = url.Values{"did": {did}, "cid": {cid}}.Encode()
	if _, err := p.DNS.Validate(ctx, parsed.String()); err != nil {
		return "", err
	}
	return parsed.String(), nil
}
