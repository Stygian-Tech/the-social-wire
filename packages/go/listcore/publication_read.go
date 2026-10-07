package listcore

import (
	"context"
	"encoding/json"
	"net/url"
	"strings"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

func splitRecordURI(uri string) []string { return strings.Split(strings.TrimPrefix(uri, "at://"), "/") }
func (r RepoReader) publicationDetails(ctx context.Context, record *gatewaycore.RepoRecord, did, uri, rkey string) (*PublicationRead, error) {
	var value map[string]any
	data, err := json.Marshal(record.Value)
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return nil, err
	}
	title := rkey
	for _, key := range []string{"name", "title"} {
		if text, ok := value[key].(string); ok && strings.TrimSpace(text) != "" {
			title = strings.TrimSpace(text)
			break
		}
	}
	base, err := r.Repo.ResolvePDS(ctx, did)
	if err != nil {
		return nil, err
	}
	result := &PublicationRead{Details: &Publication{PublicationID: uri, Title: title, AuthorDID: did, IconURL: thinappviewcore.PublicationIconURL(value, did, base)}}
	if raw, ok := value["url"].(string); ok {
		if parsed, err := url.Parse(raw); err == nil && parsed.Scheme == "https" && parsed.Hostname() != "" && parsed.User == nil {
			result.SiteURL = &raw
		}
	}
	return result, nil
}
