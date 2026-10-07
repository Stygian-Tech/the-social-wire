package semblecore

import (
	"context"
)

func (s Service) Collection(ctx context.Context, viewer, uri string, cursor *string, limit int) (CollectionPage, error) {
	out := CollectionPage{Items: []Item{}}
	did, col, key, ok := parseURI(uri)
	if !ok || col != "network.cosmik.collection" {
		return out, Invalid("`collectionUri` must identify a Semble collection.")
	}
	if did != viewer {
		return out, Forbidden
	}
	q, e := query(cursor, limit, "updatedAt")
	if e != nil {
		return out, e
	}
	q.Set("handle", did)
	q.Set("recordKey", key)
	m, e := s.get(ctx, "collection", "/network.cosmik.collection.getByAtUri", q, true)
	if e != nil {
		return out, e
	}
	if str(m, "uri") != uri || str(object(m, "author"), "id") != viewer {
		return out, upstream("Semble returned a collection that does not match the configured AT URI.")
	}
	owners := map[string]bool{viewer: true}
	needsNotes := false
	for _, v := range arr(m, "urlCards") {
		c := v.(map[string]any)
		owners[str(object(c, "author"), "id")] = true
		needsNotes = needsNotes || c["note"] != nil
	}
	collections := []string{"network.cosmik.collectionLink"}
	if needsNotes {
		collections = append(collections, "network.cosmik.card")
	}
	enrichment := s.records(ctx, owners, collections)
	out.MembershipComplete = enrichment.Complete
	out.RecordLinksComplete = enrichment.Complete
	for _, v := range arr(m, "urlCards") {
		c := v.(map[string]any)
		cardURI := str(c, "uri")
		if _, _, _, ok := parseURI(cardURI); !ok {
			return out, upstream("Semble returned a card without an AT URI.")
		}
		typ := str(c, "type")
		if typ != "URL" && typ != "NOTE" {
			return out, upstream("Semble returned an unsupported card type.")
		}
		author := object(c, "author")
		metadata := object(c, "cardContent")
		item := Item{ID: str(c, "id"), CardURI: cardURI, CardCID: opt(c, "cid"), CardType: typ, URL: opt(c, "url"), Title: opt(metadata, "title"), Description: opt(metadata, "description"), Image: opt(metadata, "imageUrl"), SiteName: opt(metadata, "siteName"), PublishedAt: opt(metadata, "publishedDate"), CreatedAt: opt(c, "createdAt"), Contributor: Contributor{str(author, "id"), opt(author, "handle"), opt(author, "name"), opt(author, "avatarUrl")}}
		if item.URL == nil {
			item.URL = opt(metadata, "url")
		}
		for _, r := range enrichment.Records {
			if r.URI == cardURI && item.CardCID == nil {
				item.CardCID = r.CID
			}
			if item.Membership != nil || r.Collection != "network.cosmik.collectionLink" {
				continue
			}
			value := decodeRecord(r)
			if !validLink(value) || str(object(value, "collection"), "uri") != uri || (str(object(value, "card"), "uri") != cardURI && str(object(value, "originalCard"), "uri") != cardURI) {
				continue
			}
			owner, _, _, ok := parseURI(r.URI)
			if !ok {
				continue
			}
			item.Membership = &Membership{r.URI, r.CID, owner, str(value, "addedBy"), opt(value, "addedAt"), owner == viewer}
		}
		if item.Membership == nil {
			out.MembershipComplete = false
			out.RecordLinksComplete = false
		} else {
			item.UnlinkAvailable = true
		}
		if note := object(c, "note"); note != nil {
			item.Note = &Note{Text: str(note, "text"), AuthorDID: str(author, "id")}
			for _, r := range enrichment.Records {
				if r.Collection != "network.cosmik.card" {
					continue
				}
				value := decodeRecord(r)
				owner, _, _, ok := parseURI(r.URI)
				if ok && validCard(value) && str(value, "type") == "NOTE" && str(object(value, "parentCard"), "uri") == cardURI && str(object(value, "content"), "text") == str(note, "text") {
					recordURI := r.URI
					item.Note = &Note{&recordURI, str(note, "text"), owner, owner == viewer}
					break
				}
			}
			if item.Note.URI == nil {
				out.RecordLinksComplete = false
			}
		}
		out.Items = append(out.Items, item)
	}
	out.Collection = collectionDTO(m, uri)
	out.Cursor = nextCursor(m)
	return out, nil
}
