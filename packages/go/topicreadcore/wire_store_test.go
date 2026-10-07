package topicreadcore

import (
	"context"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"testing"
	"time"
)

type corpusFixture struct {
	corpuscore.Store
	pages   []corpuscore.Page
	queries []corpuscore.FeedQuery
	edition corpuscore.Edition
	item    *corpuscore.Item
}

func (c *corpusFixture) Feed(ctx context.Context, q corpuscore.FeedQuery, now time.Time) (corpuscore.Page, error) {
	c.queries = append(c.queries, q)
	if len(c.pages) == 0 {
		return corpuscore.Page{}, errors.New("unexpected page")
	}
	p := c.pages[0]
	c.pages = c.pages[1:]
	return p, nil
}
func (c *corpusFixture) Edition(context.Context, corpuscore.EditionQuery, time.Time) (corpuscore.Edition, error) {
	return c.edition, nil
}
func (c *corpusFixture) Item(context.Context, string, time.Time) (*corpuscore.Item, error) {
	return c.item, nil
}
func topicItem(id string) wirecore.FeedItem {
	return wirecore.FeedItem{ItemID: id, CanonicalURL: "https://example.com/" + id, Title: id, Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}
}
func topicWire(t *testing.T, c *corpusFixture) *WireStore {
	t.Helper()
	s, e := NewWireStore(c, "01234567890123456789012345678901", "visible", &ModerationCache{})
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func TestWireModeratedContinuationBindsRawOrdinal(t *testing.T) {
	now := time.Now()
	gen := "11111111-1111-1111-1111-111111111111"
	blocked := "did:example:blocked"
	viewer := "did:example:viewer"
	rows := []corpuscore.Row{}
	for i := range 5 {
		row := corpuscore.Row{Ordinal: i, Item: topicItem(fmt.Sprint(i))}
		if i == 0 || i == 2 {
			row.SourceActorKey = &blocked
		}
		rows = append(rows, row)
	}
	c := &corpusFixture{pages: []corpuscore.Page{{GenerationID: gen, Language: "en", Source: "ranked", GeneratedAt: now, Rows: rows, Exhausted: true}}}
	s := topicWire(t, c)
	s.Moderation.Store(viewer, ModerationSnapshot{BlockedDIDs: map[string]bool{blocked: true}, FetchedAt: now})
	p, e := s.Feed(context.Background(), "", 2, "EN-us", viewer, now)
	if e != nil {
		t.Fatal(e)
	}
	if len(p.Items) != 2 || p.Items[0].ItemID != "1" || p.Items[1].ItemID != "3" || p.Cursor == nil {
		t.Fatal(p)
	}
	cursor, e := s.Cursor.Decode(*p.Cursor)
	if e != nil || cursor.NextOrdinal != 4 {
		t.Fatal(cursor, e)
	}
	if c.queries[0].Limit != 100 || c.queries[0].FallbackLimit == nil || *c.queries[0].FallbackLimit != 5000 {
		t.Fatal(c.queries)
	}
	if _, e = s.Feed(context.Background(), *p.Cursor, 2, "fr", viewer, now); !errors.Is(e, ErrInvalidCursor) {
		t.Fatal(e)
	}
}
func TestWireScanningBudgetAndFallbackDoNotExposeHiddenItems(t *testing.T) {
	now := time.Now()
	blocked := "did:example:blocked"
	gen := "11111111-1111-1111-1111-111111111111"
	rows := []corpuscore.Row{}
	for i := range 5000 {
		row := corpuscore.Row{Ordinal: i, Item: topicItem(fmt.Sprint(i)), SourceActorKey: &blocked}
		if i == 4999 {
			row.SourceActorKey = nil
		}
		rows = append(rows, row)
	}
	c := &corpusFixture{pages: []corpuscore.Page{{GenerationID: gen, Language: "en", Source: "simplified_fallback", Rows: rows, Exhausted: true}}}
	s := topicWire(t, c)
	s.Moderation.Store("viewer", ModerationSnapshot{BlockedDIDs: map[string]bool{blocked: true}, FetchedAt: now})
	p, e := s.Feed(context.Background(), "", 1, "en", "viewer", now)
	if e != nil || len(p.Items) != 1 || p.Items[0].ItemID != "4999" || p.Cursor != nil {
		t.Fatal(p, e)
	}
}
func TestEditionRequiresActorEvidenceAndReappliesModuleMinimums(t *testing.T) {
	now := time.Now()
	blocked := "did:example:blocked"
	a, b := topicItem("a"), topicItem("b")
	e := wirecore.AssembleEdition("11111111-1111-1111-1111-111111111111", now, "en", nil, "ranked", false, nil, nil)
	e.LeadStories = []wirecore.FeedItem{a, b}
	e.PublicationPanels = []wirecore.PublicationPanel{{Stories: []wirecore.FeedItem{a, b}}}
	e.GeneralStories = []wirecore.FeedItem{b}
	c := &corpusFixture{edition: corpuscore.Edition{Edition: e}}
	s := topicWire(t, c)
	s.Moderation.Store("viewer", ModerationSnapshot{BlockedDIDs: map[string]bool{blocked: true}, FetchedAt: now})
	if _, err := s.Edition(context.Background(), "en", nil, "viewer", now); !errors.Is(err, ErrUnavailable) {
		t.Fatal(err)
	}
	c.edition.SourceActorKeysByItemID = map[string]string{"a": blocked}
	actual, err := s.Edition(context.Background(), "en", nil, "viewer", now)
	if err != nil || len(actual.LeadStories) != 1 || len(actual.PublicationPanels) != 0 {
		t.Fatal(actual, err)
	}
	response := EditionResponse(actual)
	if len(response.Stories) != 1 || len(response.StoryRails) != 1 || response.StoryRails[0].ID != "more-across-the-social-web" {
		t.Fatal(response)
	}
}
func TestWireItemModerationFailClosed(t *testing.T) {
	now := time.Now()
	actor := "did:example:blocked"
	c := &corpusFixture{item: &corpuscore.Item{Item: topicItem("a"), SourceActorKey: &actor}}
	s := topicWire(t, c)
	if _, err := s.Item(context.Background(), "a", "viewer", now); !errors.Is(err, ErrModerationUnavailable) {
		t.Fatal(err)
	}
	s.Moderation.Store("viewer", ModerationSnapshot{BlockedDIDs: map[string]bool{actor: true}, FetchedAt: now})
	if item, err := s.Item(context.Background(), "a", "viewer", now); item != nil || err != nil {
		t.Fatal(item, err)
	}
}
