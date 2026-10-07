package semblecore

import (
	"context"
	"net/url"
	"strings"
)

func (s Service) Connections(ctx context.Context, viewer, target string, cursor *string, limit int) (ConnectionsResponse, error) {
	out := ConnectionsResponse{Connections: []Connection{}}
	u, e := url.Parse(target)
	if e != nil || u.Hostname() == "" || (strings.ToLower(u.Scheme) != "http" && strings.ToLower(u.Scheme) != "https") {
		return out, Invalid("`url` must be an absolute HTTP(S) URL.")
	}
	q, e := query(cursor, limit, "createdAt")
	if e != nil {
		return out, e
	}
	q.Set("url", target)
	q.Set("direction", "both")
	m, e := s.get(ctx, "connections", "/network.cosmik.connection.getForUrl", q, false)
	if e != nil {
		return out, e
	}
	owners := map[string]bool{}
	for _, v := range arr(m, "connections") {
		owners[str(object(object(v.(map[string]any), "connection"), "curator"), "id")] = true
	}
	enrichment := s.records(ctx, owners, []string{"network.cosmik.connection"})
	out.RecordLinksComplete = enrichment.Complete
	for _, v := range arr(m, "connections") {
		row := v.(map[string]any)
		c := object(row, "connection")
		author := str(object(c, "curator"), "id")
		item := Connection{Source: str(object(row, "source"), "url"), Target: str(object(row, "target"), "url"), ConnectionType: opt(c, "type"), Note: opt(c, "note"), CreatedAt: opt(c, "createdAt"), UpdatedAt: opt(c, "updatedAt"), AuthorDID: author}
		for _, r := range enrichment.Records {
			value := decodeRecord(r)
			owner, _, _, ok := parseURI(r.URI)
			if !ok || owner != author || !required(value, "source", "string") || !required(value, "target", "string") || !optionalStrings(value, "connectionType", "note", "createdAt", "updatedAt") {
				continue
			}
			if str(value, "source") == item.Source && str(value, "target") == item.Target && eq(opt(value, "connectionType"), item.ConnectionType) && eq(opt(value, "note"), item.Note) {
				recordURI := r.URI
				item.URI = &recordURI
				item.Editable = owner == viewer
				break
			}
		}
		if item.URI == nil {
			out.RecordLinksComplete = false
		}
		out.Connections = append(out.Connections, item)
	}
	out.Cursor = nextCursor(m)
	return out, nil
}
