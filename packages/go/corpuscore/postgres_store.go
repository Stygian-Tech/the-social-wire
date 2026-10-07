package corpuscore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type PostgreSQLStore struct {
	DB    *sql.DB
	Cache *PayloadCache
}

var _ Store = (*PostgreSQLStore)(nil)

type generation struct {
	id, language       string
	generated, expires time.Time
	recovering         bool
}
type record struct {
	values []any
	err    error
}

func (r *record) String(i int) string {
	switch value := r.values[i].(type) {
	case string:
		return value
	case []byte:
		return string(value)
	}
	r.err = ErrContractMismatch
	return ""
}
func (r *record) OptionalString(i int) *string {
	if r.values[i] == nil {
		return nil
	}
	value := r.String(i)
	return &value
}
func (r *record) Int(i int) int {
	switch value := r.values[i].(type) {
	case int64:
		return int(value)
	case int32:
		return int(value)
	case int:
		return value
	}
	r.err = ErrContractMismatch
	return 0
}
func (r *record) Float(i int) float64 {
	switch value := r.values[i].(type) {
	case float64:
		return value
	case int64:
		return float64(value)
	case string:
		number, err := strconv.ParseFloat(value, 64)
		if err == nil {
			return number
		}
	}
	r.err = ErrContractMismatch
	return 0
}
func (r *record) Bool(i int) bool {
	value, ok := r.values[i].(bool)
	if !ok {
		r.err = ErrContractMismatch
	}
	return value
}
func (r *record) Time(i int) time.Time {
	value, ok := r.values[i].(time.Time)
	if !ok {
		r.err = ErrContractMismatch
	}
	return value.UTC()
}
func (r *record) OptionalTime(i int) *time.Time {
	if r.values[i] == nil {
		return nil
	}
	value := r.Time(i)
	return &value
}
func (s *PostgreSQLStore) query(ctx context.Context, statement string, args ...any) ([]*record, error) {
	rows, err := s.DB.QueryContext(ctx, statement, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	columns, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	result := []*record{}
	for rows.Next() {
		value := &record{values: make([]any, len(columns))}
		targets := make([]any, len(columns))
		for i := range targets {
			targets[i] = &value.values[i]
		}
		if err := rows.Scan(targets...); err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	return result, rows.Err()
}
func (s *PostgreSQLStore) Ping(ctx context.Context) error {
	rows, err := s.query(ctx, `SELECT contract_version FROM wire_serving.contract LIMIT 1`)
	if err != nil {
		return err
	}
	if len(rows) != 1 || rows[0].Int(0) != 3 {
		return ErrContractMismatch
	}
	return rows[0].err
}
func (s *PostgreSQLStore) RequireFreshBaseline(ctx context.Context, now time.Time) error {
	rows, err := s.query(ctx, `SELECT has_current_snapshot,oldest_successful_at FROM wire_serving.label_health`)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return ErrModerationUnavailable
	}
	row := rows[0]
	if row.values[0] == nil || !row.Bool(0) || row.OptionalTime(1) == nil || row.Time(1).Before(now.Add(-30*time.Minute)) {
		return ErrModerationUnavailable
	}
	return row.err
}
func (s *PostgreSQLStore) generations(ctx context.Context, statement string, args ...any) ([]generation, error) {
	rows, err := s.query(ctx, statement, args...)
	if err != nil {
		return nil, err
	}
	result := []generation{}
	for _, row := range rows {
		result = append(result, generation{strings.ToLower(row.String(0)), row.String(1), row.Time(2), row.Time(3), row.Bool(4)})
		if row.err != nil {
			return nil, row.err
		}
	}
	return result, nil
}
func (s *PostgreSQLStore) activeGeneration(ctx context.Context, language string, now time.Time) (*generation, error) {
	values, err := s.generations(ctx, `SELECT generation_id,language_bucket,generated_at,expires_at,recovering FROM wire_serving.feed_state WHERE language_bucket=$1 AND expires_at>$2 LIMIT 1`, language, now)
	if err != nil || len(values) == 0 {
		return nil, err
	}
	return &values[0], nil
}
func (s *PostgreSQLStore) retainedGeneration(ctx context.Context, id string, now time.Time) (*generation, error) {
	values, err := s.generations(ctx, `SELECT generation_id,language_bucket,generated_at,expires_at,recovering FROM wire_serving.generations WHERE generation_id=$1::uuid AND expires_at>$2 LIMIT 1`, id, now)
	if err != nil || len(values) == 0 {
		return nil, err
	}
	return &values[0], nil
}
func (s *PostgreSQLStore) Feed(ctx context.Context, q FeedQuery, now time.Time) (Page, error) {
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return Page{}, err
	}
	var gen *generation
	var err error
	if q.GenerationID != nil {
		gen, err = s.retainedGeneration(ctx, *q.GenerationID, now)
		if err != nil {
			return Page{}, err
		}
		if gen == nil || gen.language != q.Language {
			return Page{}, ErrCursorExpired
		}
	} else {
		gen, err = s.activeGeneration(ctx, q.Language, now)
		if err != nil {
			return Page{}, err
		}
	}
	fallbackLimit := q.Limit
	if q.FallbackLimit != nil {
		fallbackLimit = *q.FallbackLimit
	}
	if gen == nil {
		return s.fallback(ctx, q.Language, min(5000, max(1, fallbackLimit)), now)
	}
	rows, err := s.cachedRankedRows(ctx, gen, q.StartOrdinal, q.Limit, now)
	if err != nil {
		return Page{}, err
	}
	if len(rows) == 0 && q.GenerationID == nil {
		return s.fallback(ctx, q.Language, min(5000, max(1, fallbackLimit)), now)
	}
	stale := now.Sub(gen.generated) > 10*time.Minute
	source := "ranked"
	if stale {
		source = "stale_generation"
	}
	return Page{gen.id, gen.generated, gen.language, source, gen.recovering || stale, rows, len(rows) < q.Limit}, nil
}
func decodeItem(row *record, offset int, reasons string, metadata int) wirecore.FeedItem {
	item := wirecore.FeedItem{ItemID: row.String(offset), CanonicalURL: row.String(offset + 1), RepresentativeURI: row.OptionalString(offset + 2), Title: row.String(offset + 3), Summary: row.OptionalString(offset + 4), PublishedAt: row.OptionalTime(offset + 5), ThumbnailURL: row.OptionalString(offset + 6), Source: wirecore.ItemSource{Name: row.String(offset + 7), Domain: row.String(offset + 8), Publication: row.OptionalString(offset + 9), Author: row.OptionalString(offset + 10)}, Reasons: []wirecore.ReasonCode{}, Provenance: []string{}}
	if metadata >= 0 {
		item.Source.PublicationKey = row.OptionalString(metadata)
		item.Source.HomepageURL = row.OptionalString(metadata + 1)
		item.Source.IconURL = row.OptionalString(metadata + 2)
	}
	if json.Unmarshal([]byte(reasons), &item.Reasons) != nil {
		item.Reasons = []wirecore.ReasonCode{}
	}
	if item.Reasons == nil {
		item.Reasons = []wirecore.ReasonCode{}
	}
	if json.Unmarshal([]byte(row.String(offset+11)), &item.Provenance) != nil {
		item.Provenance = []string{}
	}
	for _, kind := range item.Provenance {
		switch kind {
		case "standard_site", "recommendation", "direct_share", "quote", "repost", "like", "rss":
		default:
			item.Provenance = []string{}
		}
	}
	if item.Provenance == nil {
		item.Provenance = []string{}
	}
	item.Reasons = item.Reasons[:min(2, len(item.Reasons))]
	item.Provenance = item.Provenance[:min(8, len(item.Provenance))]
	return item
}
func (s *PostgreSQLStore) rankedRows(ctx context.Context, id string, start, limit int) ([]Row, error) {
	rows, err := s.query(ctx, `SELECT position,canonical_key,canonical_url,representative_uri,title,summary,published_at,thumbnail_url,source_name,source_domain,publication_id,author_name,provenance::text,author_key,reason_codes::text,publication_key,publication_homepage_url,publication_icon_url FROM wire_serving.ranked_items WHERE generation_id=$1::uuid AND position>=$2 ORDER BY position LIMIT $3`, id, start, limit)
	if err != nil {
		return nil, err
	}
	result := []Row{}
	for _, row := range rows {
		result = append(result, Row{row.Int(0), decodeItem(row, 1, row.String(14), 15), row.OptionalString(13)})
		if row.err != nil {
			return nil, row.err
		}
	}
	return result, nil
}
func (s *PostgreSQLStore) revisionRows(ctx context.Context, statement string, args ...any) (string, error) {
	rows, err := s.query(ctx, statement, args...)
	if err != nil {
		return "", err
	}
	tokens := []string{}
	for _, row := range rows {
		tokens = append(tokens, row.String(0))
		if row.err != nil {
			return "", row.err
		}
	}
	return strings.Join(tokens, "\n"), nil
}
func (s *PostgreSQLStore) rankedRevision(ctx context.Context, id string, start, limit int) (string, error) {
	return s.revisionRows(ctx, `SELECT json_build_array(position,canonical_key,cache_revision)::text FROM wire_serving.ranked_items WHERE generation_id=$1::uuid AND position>=$2 ORDER BY position LIMIT $3`, id, start, limit)
}
func revisionIdentities(revision string, index int) map[string]bool {
	keys := map[string]bool{}
	for _, token := range strings.Split(revision, "\n") {
		var fields []any
		if json.Unmarshal([]byte(token), &fields) == nil && len(fields) > index {
			if value, ok := fields[index].(string); ok {
				keys[value] = true
			}
		}
	}
	return keys
}
func (s *PostgreSQLStore) cachedRankedRows(ctx context.Context, g *generation, start, limit int, now time.Time) ([]Row, error) {
	load := func(ctx context.Context) ([]Row, error) { return s.rankedRows(ctx, g.id, start, limit) }
	if s.Cache == nil {
		return load(ctx)
	}
	revision, err := s.rankedRevision(ctx, g.id, start, limit)
	if err != nil {
		return nil, err
	}
	keys := revisionIdentities(revision, 1)
	return cachedValue(ctx, s.Cache, []string{"feed", strings.ToUpper(g.id), g.language, strconv.Itoa(start), strconv.Itoa(limit)}, revision, now, GenerationLifetime(g.expires, now), func(ctx context.Context) (string, error) { return s.rankedRevision(ctx, g.id, start, limit) }, func(rows []Row) bool {
		if len(rows) != len(keys) {
			return false
		}
		for _, row := range rows {
			if !keys[row.Item.ItemID] {
				return false
			}
		}
		return true
	}, load)
}
func (s *PostgreSQLStore) loadItem(ctx context.Context, id string) (*Item, error) {
	rows, err := s.query(ctx, `SELECT canonical_key,canonical_url,representative_uri,title,summary,published_at,thumbnail_url,source_name,source_domain,publication_id,author_name,provenance::text,author_key,publication_key,publication_homepage_url,publication_icon_url FROM wire_serving.items WHERE canonical_key=$1 LIMIT 1`, id)
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	row := rows[0]
	value := &Item{decodeItem(row, 0, "[]", 13), row.OptionalString(12)}
	return value, row.err
}
func (s *PostgreSQLStore) itemRevision(ctx context.Context, id string) (string, error) {
	return s.revisionRows(ctx, `SELECT json_build_array(canonical_key,cache_revision)::text FROM wire_serving.items WHERE canonical_key=$1 LIMIT 1`, id)
}
func (s *PostgreSQLStore) Item(ctx context.Context, id string, now time.Time) (*Item, error) {
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return nil, err
	}
	if s.Cache == nil {
		return s.loadItem(ctx, id)
	}
	revision, err := s.itemRevision(ctx, id)
	if err != nil || revision == "" {
		return nil, err
	}
	return cachedValue(ctx, s.Cache, []string{"item", id}, revision, now, 10*time.Minute, func(ctx context.Context) (string, error) { return s.itemRevision(ctx, id) }, func(value *Item) bool { return value != nil && value.Item.ItemID == id }, func(ctx context.Context) (*Item, error) { return s.loadItem(ctx, id) })
}

type catalogSnapshot struct {
	Value     Catalog   `json:"value"`
	ExpiresAt time.Time `json:"expiresAt"`
}

func (s *PostgreSQLStore) loadCatalog(ctx context.Context, now time.Time) (catalogSnapshot, error) {
	gens, err := s.generations(ctx, `SELECT generation_id,language_bucket,generated_at,expires_at,recovering FROM wire_serving.feed_state WHERE expires_at>$1`, now)
	if err != nil {
		return catalogSnapshot{}, err
	}
	value := Catalog{SupportedLanguages: []string{}}
	expires := now.Add(5 * time.Second)
	var latest *generation
	for index, g := range gens {
		if g.language != "und" {
			value.SupportedLanguages = append(value.SupportedLanguages, g.language)
		}
		if latest == nil || g.generated.After(latest.generated) {
			latest = &gens[index]
		}
		if index == 0 || g.expires.Before(expires) {
			expires = g.expires
		}
	}
	sort.Strings(value.SupportedLanguages)
	value.SupportedLanguages = value.SupportedLanguages[:min(12, len(value.SupportedLanguages))]
	if latest != nil {
		value.Available = true
		value.LatestGenerationID = &latest.id
		value.GeneratedAt = &latest.generated
	} else {
		value.Available, err = s.hasFallback(ctx)
	}
	return catalogSnapshot{value, expires}, err
}
func (s *PostgreSQLStore) Catalog(ctx context.Context, now time.Time) (Catalog, error) {
	if err := s.RequireFreshBaseline(ctx, now); err != nil {
		return Catalog{}, err
	}
	snapshot, err := cachedValue(ctx, s.Cache, []string{"catalog"}, "advisory-v1", now, 5*time.Second, func(context.Context) (string, error) { return "advisory-v1", nil }, nil, func(ctx context.Context) (catalogSnapshot, error) { return s.loadCatalog(ctx, now) })
	if err != nil {
		return Catalog{}, err
	}
	if !snapshot.ExpiresAt.After(now) {
		snapshot, err = s.loadCatalog(ctx, now)
	}
	return snapshot.Value, err
}
func (s *PostgreSQLStore) hasFallback(ctx context.Context) (bool, error) {
	rows, err := s.query(ctx, `SELECT COUNT(*)::bigint FROM (SELECT 1 FROM wire_serving.fallback_candidates WHERE baseline_admitted LIMIT $1) AS bounded`, wirecore.MinimumGlobalCandidates)
	if err != nil {
		return false, err
	}
	if len(rows) == 0 {
		return false, ErrContractMismatch
	}
	return rows[0].Int(0) >= wirecore.MinimumGlobalCandidates, rows[0].err
}
func checkRecords(rows []*record) error {
	for _, row := range rows {
		if row.err != nil {
			return fmt.Errorf("serving row: %w", row.err)
		}
	}
	return nil
}
