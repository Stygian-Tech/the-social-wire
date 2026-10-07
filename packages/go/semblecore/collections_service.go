package semblecore

import (
	"context"
)

func (s Service) Collections(ctx context.Context, viewer string, cursor *string, limit int) (CollectionsResponse, error) {
	out := CollectionsResponse{Collections: []Collection{}}
	q, e := query(cursor, limit, "updatedAt")
	if e != nil {
		return out, e
	}
	q.Set("identifier", viewer)
	m, e := s.get(ctx, "collections", "/network.cosmik.collection.listByUser", q, false)
	if e != nil {
		return out, e
	}
	for _, v := range arr(m, "collections") {
		c := v.(map[string]any)
		uri := str(c, "uri")
		did, col, _, ok := parseURI(uri)
		if !ok || col != "network.cosmik.collection" || did != viewer || str(object(c, "author"), "id") != viewer {
			return out, upstream("Semble returned a collection outside the authenticated viewer's repository.")
		}
		out.Collections = append(out.Collections, collectionDTO(c, uri))
	}
	out.Cursor = nextCursor(m)
	return out, nil
}
