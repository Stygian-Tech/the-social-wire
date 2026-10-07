package wireworkercore

import (
	"context"
	"database/sql"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

var (
	ErrMalformedDocument     = errors.New("malformed standard document")
	ErrUnresolvedPublication = errors.New("unresolved publication")
	ErrUnaddressableDocument = errors.New("unaddressable standard document")
)

type PublicationMetadata struct{ URI, RepoDID, SiteURL, Name string }
type PublicationResolver interface {
	Resolve(context.Context, string, time.Time) (*PublicationMetadata, error)
	Invalidate(string)
	InvalidateAccount(string)
}
type BlobResolver interface {
	ResolveBlobURL(context.Context, string, string) (string, error)
}
type ResolvedDocument struct {
	CanonicalURL                                            string
	PublicationURI, PublicationName, PublicationHomepageURL *string
}
type PublicationReference struct{ URI, RepoDID, Collection, RecordKey string }

func ParsePublicationReference(raw string) *PublicationReference {
	if len(raw) > 512 || !strings.HasPrefix(raw, "at://") {
		return nil
	}
	parts := strings.Split(strings.TrimPrefix(raw, "at://"), "/")
	if len(parts) != 3 {
		return nil
	}
	did := strings.TrimSpace(parts[0])
	if strings.HasPrefix(strings.ToLower(did), "did:plc:") {
		did = strings.ToLower(did)
	}
	if !strings.HasPrefix(did, "did:") || parts[2] == "" || parts[1] != "site.standard.publication" && parts[1] != "com.standard.publication" {
		return nil
	}
	return &PublicationReference{"at://" + did + "/" + parts[1] + "/" + parts[2], did, parts[1], parts[2]}
}
func recordString(record map[string]any, keys ...string) string {
	for _, key := range keys {
		if text, ok := record[key].(string); ok {
			if text = strings.TrimSpace(text); text != "" {
				return text
			}
		}
	}
	return ""
}
func stringPointer(text string) *string {
	if text == "" {
		return nil
	}
	return &text
}
func normalizedHTTPS(raw string, removeQuery bool) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.User != nil || u.Hostname() == "" || strings.ToLower(u.Scheme) != "http" && strings.ToLower(u.Scheme) != "https" {
		return ""
	}
	u.Scheme = "https"
	u.Fragment = ""
	u.RawFragment = ""
	if removeQuery {
		u.RawQuery = ""
		u.ForceQuery = false
	}
	return strings.TrimRight(u.String(), "/")
}
func publicationBase(record map[string]any) string {
	for _, key := range []string{"url", "siteUrl", "site", "homepage"} {
		if value, ok := record[key].(string); ok {
			if normalized := normalizedHTTPS(value, true); normalized != "" {
				return normalized
			}
		}
	}
	return ""
}
func articleURL(path, base string) string {
	if absolute := normalizedHTTPS(path, false); absolute != "" {
		return absolute
	}
	base = normalizedHTTPS(base, true)
	if base == "" {
		return ""
	}
	path = strings.Trim(strings.TrimSpace(path), "/")
	if path == "" {
		return base
	}
	return normalizedHTTPS(base+"/"+path, false)
}
func ParsePublicationMetadata(uri, repo string, record map[string]any) *PublicationMetadata {
	ref := ParsePublicationReference(uri)
	if strings.HasPrefix(strings.ToLower(repo), "did:plc:") {
		repo = strings.ToLower(strings.TrimSpace(repo))
	}
	site := publicationBase(record)
	if ref == nil || ref.RepoDID != repo || site == "" {
		return nil
	}
	name := recordString(record, "name", "title")
	if name == "" {
		u, _ := url.Parse(site)
		name = u.Hostname()
	}
	if len([]rune(name)) > 500 {
		name = string([]rune(name)[:500])
	}
	return &PublicationMetadata{ref.URI, ref.RepoDID, site, name}
}
func documentPublicationURI(record map[string]any) string {
	for _, key := range []string{"site", "publication", "publicationUri", "publicationId"} {
		value := record[key]
		text, _ := value.(string)
		if object, ok := value.(map[string]any); ok {
			text, _ = object["uri"].(string)
		}
		if ref := ParsePublicationReference(text); ref != nil {
			return ref.URI
		}
	}
	return ""
}
func ResolveDocument(ctx context.Context, record map[string]any, resolver PublicationResolver, at time.Time) (*ResolvedDocument, error) {
	uri := documentPublicationURI(record)
	if direct := recordString(record, "canonicalUrl", "url", "externalUrl", "href", "permalink"); direct != "" {
		if normalized := articleURL(direct, direct); normalized != "" {
			d := &ResolvedDocument{CanonicalURL: normalized, PublicationURI: stringPointer(uri)}
			if uri != "" && resolver != nil {
				metadata, err := resolver.Resolve(ctx, uri, at)
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				if err == nil && metadata != nil {
					d.PublicationName = &metadata.Name
					d.PublicationHomepageURL = &metadata.SiteURL
				}
			}
			return d, nil
		}
	}
	path := recordString(record, "path")
	if path == "" {
		site := recordString(record, "site")
		if recordString(record, "title") != "" && recordString(record, "publishedAt") != "" && (ParsePublicationReference(site) != nil || publicationBase(map[string]any{"url": site}) != "") {
			return nil, ErrUnaddressableDocument
		}
		return nil, ErrMalformedDocument
	}
	if site := recordString(record, "site", "siteUrl", "homepage"); site != "" {
		if normalized := articleURL(path, site); normalized != "" {
			return &ResolvedDocument{CanonicalURL: normalized, PublicationHomepageURL: stringPointer(publicationBase(map[string]any{"url": site}))}, nil
		}
	}
	if uri == "" {
		return nil, ErrMalformedDocument
	}
	if resolver == nil {
		return nil, ErrUnresolvedPublication
	}
	metadata, err := resolver.Resolve(ctx, uri, at)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, ErrUnresolvedPublication
	}
	if metadata == nil {
		return nil, ErrUnresolvedPublication
	}
	normalized := articleURL(path, metadata.SiteURL)
	if normalized == "" {
		return nil, ErrUnresolvedPublication
	}
	return &ResolvedDocument{normalized, &metadata.URI, &metadata.Name, &metadata.SiteURL}, nil
}
func SavePublicationMetadata(ctx context.Context, tx *sql.Tx, metadata PublicationMetadata, at time.Time, fenced bool) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO wire_publications(publication_uri,repo_did,site_url,name,metadata,first_seen_at,last_seen_at,expires_at,updated_at) VALUES($1,$2,$3,$4,'{}'::jsonb,$5,$5,$6,$5) ON CONFLICT(publication_uri) DO UPDATE SET repo_did=EXCLUDED.repo_did,site_url=EXCLUDED.site_url,name=EXCLUDED.name,last_seen_at=EXCLUDED.last_seen_at,expires_at=EXCLUDED.expires_at,updated_at=EXCLUDED.updated_at WHERE($7 OR wire_publications.last_seen_at<=EXCLUDED.last_seen_at) AND(wire_publications.repo_did,wire_publications.site_url,wire_publications.name,wire_publications.last_seen_at,wire_publications.expires_at)IS DISTINCT FROM(EXCLUDED.repo_did,EXCLUDED.site_url,EXCLUDED.name,EXCLUDED.last_seen_at,EXCLUDED.expires_at)`, metadata.URI, metadata.RepoDID, metadata.SiteURL, metadata.Name, at, at.Add(wirecore.ItemRetention), fenced)
	return err
}
