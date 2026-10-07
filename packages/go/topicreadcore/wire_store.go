package topicreadcore

import (
	"context"
	"encoding/hex"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strconv"
	"strings"
	"time"
)

type WireStore struct {
	Corpus     corpuscore.Store
	Cursor     *wirecore.CursorCodec
	Mode       string
	Moderation *ModerationCache
}
type WirePage struct {
	GenerationID string              `json:"generationId"`
	GeneratedAt  time.Time           `json:"generatedAt"`
	Language     string              `json:"language"`
	Cursor       *string             `json:"cursor,omitempty"`
	Source       string              `json:"source"`
	Degraded     bool                `json:"degraded"`
	Items        []wirecore.FeedItem `json:"items"`
}
type WireItemDetail struct {
	Item     wirecore.FeedItem `json:"item"`
	EmbedURL string            `json:"embedUrl"`
}
type WireCatalog struct {
	Enabled            bool       `json:"enabled"`
	Available          bool       `json:"available"`
	SupportedLanguages []string   `json:"supportedLanguages"`
	LatestGenerationID *string    `json:"latestGenerationId,omitempty"`
	GeneratedAt        *time.Time `json:"generatedAt,omitempty"`
}

func NewWireStore(corpus corpuscore.Store, secret, mode string, moderation *ModerationCache) (*WireStore, error) {
	if mode != "off" && mode != "shadow" && mode != "api" && mode != "visible" {
		return nil, ErrUnavailable
	}
	codec, err := wirecore.NewCursorCodec([]byte(secret))
	if err != nil {
		return nil, err
	}
	if corpus == nil || moderation == nil {
		return nil, ErrUnavailable
	}
	return &WireStore{corpus, codec, mode, moderation}, nil
}
func PrimaryLanguage(raw string) string {
	raw = strings.ToLower(strings.TrimSpace(raw))
	parts := strings.FieldsFunc(raw, func(r rune) bool { return r == '-' })
	if len(parts) == 0 {
		return "und"
	}
	raw = parts[0]
	if len(raw) < 2 || len(raw) > 8 {
		return "und"
	}
	for _, r := range raw {
		if r < 'a' || r > 'z' {
			return "und"
		}
	}
	return raw
}
func (s *WireStore) serves() bool { return s.Mode == "api" || s.Mode == "visible" }
func (s *WireStore) moderation(viewer string, now time.Time) (*ModerationSnapshot, error) {
	if viewer == "" {
		return nil, nil
	}
	snapshot := s.Moderation.Usable(viewer, now)
	if snapshot == nil {
		return nil, ErrModerationUnavailable
	}
	return snapshot, nil
}
func allows(snapshot *ModerationSnapshot, actor *string, item wirecore.FeedItem) bool {
	if snapshot == nil {
		return true
	}
	key := item.ItemID
	if actor != nil {
		key = *actor
	}
	return snapshot.Allows(key, item.Title, item.Summary, item.RepresentativeURI)
}
func corpusError(err error) error {
	var status corpuscore.RemoteStatusError
	if errors.As(err, &status) {
		switch status.Status {
		case 400:
			return ErrInvalidCursor
		case 503:
			return ErrModerationUnavailable
		}
	}

	if errors.Is(err, corpuscore.ErrCursorExpired) {
		return ErrCursorExpired
	}
	if errors.Is(err, corpuscore.ErrModerationUnavailable) {
		return ErrModerationUnavailable
	}
	return ErrUnavailable
}
func (s *WireStore) Feed(ctx context.Context, cursor string, limit int, language, viewer string, now time.Time) (WirePage, error) {
	if !s.serves() {
		return WirePage{}, ErrUnavailable
	}
	limit = max(1, min(limit, 50))
	language = PrimaryLanguage(language)
	var generation *string
	ordinal := 0
	if cursor != "" {
		decoded, err := s.Cursor.Decode(cursor)
		if err != nil || decoded.Language != language {
			return WirePage{}, ErrInvalidCursor
		}
		if !validUUID(decoded.GenerationID) {
			return WirePage{}, ErrInvalidCursor
		}
		generation = &decoded.GenerationID
		ordinal = decoded.NextOrdinal
	}
	snapshot, err := s.moderation(viewer, now)
	if err != nil {
		return WirePage{}, err
	}
	accepted := []corpuscore.Row{}
	var previous *corpuscore.Page
	exhausted := false
	scanned := 0
	for len(accepted) <= limit && !exhausted && scanned < 5000 {
		batch := 500
		if scanned == 0 {
			batch = 100
		}
		batch = min(batch, 5000-scanned)
		var fallback *int
		if generation == nil {
			n := 5000
			fallback = &n
		}
		page, err := s.Corpus.Feed(ctx, corpuscore.FeedQuery{Language: language, GenerationID: generation, StartOrdinal: ordinal, Limit: batch, FallbackLimit: fallback}, now)
		if errors.Is(corpusError(err), ErrInvalidCursor) && generation == nil {
			if viewer != "" {
				return WirePage{}, ErrUnavailable
			}
			page, err = s.Corpus.Feed(ctx, corpuscore.FeedQuery{Language: language, StartOrdinal: ordinal, Limit: batch}, now)
		}
		if err != nil {
			return WirePage{}, corpusError(err)
		}
		maxRows := batch
		if page.Source == "simplified_fallback" {
			maxRows = 5000
		}
		if page.Language != language || len(page.Rows) > maxRows {
			return WirePage{}, ErrUnavailable
		}
		if generation != nil && page.GenerationID != *generation {
			return WirePage{}, ErrCursorExpired
		}
		if previous != nil && (previous.GenerationID != page.GenerationID || previous.Language != page.Language) {
			return WirePage{}, ErrUnavailable
		}
		generation = &page.GenerationID
		previous = &page
		scanned += len(page.Rows)
		if len(page.Rows) > 0 {
			ordinal = page.Rows[len(page.Rows)-1].Ordinal + 1
		}
		for _, row := range page.Rows {
			if allows(snapshot, row.SourceActorKey, row.Item) {
				accepted = append(accepted, row)
			}
		}
		exhausted = page.Exhausted || page.Source == "simplified_fallback" || len(page.Rows) == 0
	}
	if previous == nil {
		return WirePage{}, ErrUnavailable
	}
	items := []wirecore.FeedItem{}
	for _, row := range accepted[:min(limit, len(accepted))] {
		items = append(items, row.Item)
	}
	var next *string
	if previous.Source != "simplified_fallback" && (len(accepted) > limit || !exhausted) {
		if len(accepted) > limit {
			ordinal = accepted[limit-1].Ordinal + 1
		}
		encoded, err := s.Cursor.Encode(wirecore.Cursor{GenerationID: previous.GenerationID, Language: language, NextOrdinal: ordinal})
		if err != nil {
			return WirePage{}, ErrUnavailable
		}
		next = &encoded
	}
	return WirePage{previous.GenerationID, previous.GeneratedAt, language, next, previous.Source, previous.Degraded, items}, nil
}
func (s *WireStore) Edition(ctx context.Context, language string, region *string, viewer string, now time.Time) (wirecore.Edition, error) {
	if !s.serves() {
		return wirecore.Edition{}, ErrUnavailable
	}
	language = PrimaryLanguage(language)
	fallback := 5000
	corpus, err := s.Corpus.Edition(ctx, corpuscore.EditionQuery{Language: language, Region: region, FallbackLimit: &fallback}, now)
	if errors.Is(corpusError(err), ErrInvalidCursor) {
		if region == nil && viewer != "" {
			return wirecore.Edition{}, ErrUnavailable
		}
		var bounded *int
		if viewer != "" {
			bounded = &fallback
		}
		corpus, err = s.Corpus.Edition(ctx, corpuscore.EditionQuery{Language: language, FallbackLimit: bounded}, now)
		if viewer != "" && errors.Is(corpusError(err), ErrInvalidCursor) {
			return wirecore.Edition{}, ErrUnavailable
		}
	}
	if err != nil {
		return wirecore.Edition{}, corpusError(err)
	}
	edition := corpus.Edition
	if edition.Language != language {
		return wirecore.Edition{}, ErrUnavailable
	}
	snapshot, err := s.moderation(viewer, now)
	if err != nil {
		return wirecore.Edition{}, err
	}
	if snapshot != nil && corpus.SourceActorKeysByItemID == nil {
		return wirecore.Edition{}, ErrUnavailable
	}
	filter := func(items []wirecore.FeedItem) []wirecore.FeedItem {
		result := []wirecore.FeedItem{}
		for _, item := range items {
			var actor *string
			if key, ok := corpus.SourceActorKeysByItemID[item.ItemID]; ok {
				actor = &key
			}
			if allows(snapshot, actor, item) {
				result = append(result, item)
			}
		}
		return result
	}
	if edition.Source == "simplified_fallback" {
		if corpus.FallbackRows != nil {
			if len(corpus.FallbackRows) > 5000 {
				return wirecore.Edition{}, ErrUnavailable
			}
			items := []wirecore.FeedItem{}
			for _, row := range corpus.FallbackRows {
				if allows(snapshot, row.SourceActorKey, row.Item) {
					items = append(items, row.Item)
					if len(items) == 50 {
						break
					}
				}
			}
			accounts := edition.TalkedAboutAccounts
			edition = wirecore.AssembleEdition(edition.GenerationID, edition.GeneratedAt, language, nil, edition.Source, edition.Degraded, items, nil)
			edition.TalkedAboutAccounts = accounts
		} else if snapshot != nil {
			return wirecore.Edition{}, ErrUnavailable
		}
	}
	edition.LeadStories = filter(edition.LeadStories)
	panels := []wirecore.PublicationPanel{}
	for _, panel := range edition.PublicationPanels {
		panel.Stories = filter(panel.Stories)
		if len(panel.Stories) >= 2 {
			panels = append(panels, panel)
		}
	}
	edition.PublicationPanels = panels
	rails := []wirecore.StoryRail{}
	for _, rail := range edition.StoryRails {
		rail.Stories = filter(rail.Stories)
		if len(rail.Stories) >= 4 {
			rails = append(rails, rail)
		}
	}
	edition.StoryRails = rails
	edition.GeneralStories = filter(edition.GeneralStories)
	edition.TrendingStories = filter(edition.TrendingStories)
	accounts := []wirecore.TalkedAboutAccount{}
	for _, account := range edition.TalkedAboutAccounts {
		title := account.DID
		if account.Handle != nil {
			title = *account.Handle
		}
		if account.DisplayName != nil {
			title = *account.DisplayName
		}
		if snapshot == nil || snapshot.Allows(account.DID, title, nil, nil) {
			accounts = append(accounts, account)
		}
	}
	if len(accounts) < 4 {
		accounts = []wirecore.TalkedAboutAccount{}
	}
	edition.TalkedAboutAccounts = accounts
	if edition.Cursor != nil {
		ordinal, err := strconv.Atoi(*edition.Cursor)
		edition.Cursor = nil
		if err == nil {
			encoded, err := s.Cursor.Encode(wirecore.Cursor{GenerationID: edition.GenerationID, Language: language, NextOrdinal: ordinal})
			if err != nil {
				return wirecore.Edition{}, ErrUnavailable
			}
			edition.Cursor = &encoded
		}
	}
	return edition, nil
}
func (s *WireStore) Item(ctx context.Context, id, viewer string, now time.Time) (*WireItemDetail, error) {
	if !s.serves() {
		return nil, ErrUnavailable
	}
	item, err := s.Corpus.Item(ctx, id, now)
	if err != nil {
		return nil, corpusError(err)
	}
	if item == nil {
		return nil, nil
	}
	snapshot, err := s.moderation(viewer, now)
	if err != nil {
		return nil, err
	}
	if !allows(snapshot, item.SourceActorKey, item.Item) {
		return nil, nil
	}
	return &WireItemDetail{item.Item, item.Item.CanonicalURL}, nil
}
func (s *WireStore) Catalog(ctx context.Context, now time.Time) (WireCatalog, error) {
	if !s.serves() {
		return WireCatalog{SupportedLanguages: []string{}}, nil
	}
	catalog, err := s.Corpus.Catalog(ctx, now)
	if err != nil {
		return WireCatalog{}, corpusError(err)
	}
	return WireCatalog{true, s.Mode == "visible" && catalog.Available, catalog.SupportedLanguages, catalog.LatestGenerationID, catalog.GeneratedAt}, nil
}

func validUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for _, i := range []int{8, 13, 18, 23} {
		if value[i] != '-' {
			return false
		}
	}
	raw := strings.ReplaceAll(value, "-", "")
	if len(raw) != 32 {
		return false
	}
	_, err := hex.DecodeString(raw)
	return err == nil
}
