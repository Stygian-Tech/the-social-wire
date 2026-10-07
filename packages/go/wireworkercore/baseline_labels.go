package wireworkercore

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

type LabelRecord struct {
	Source    string  `json:"src"`
	Subject   string  `json:"uri"`
	Value     string  `json:"val"`
	Negated   bool    `json:"neg"`
	CreatedAt string  `json:"cts"`
	ExpiresAt *string `json:"exp"`
}
type LabelPage struct {
	Cursor *string       `json:"cursor"`
	Labels []LabelRecord `json:"labels"`
}
type LabelTarget struct {
	CanonicalKey                 string
	RepresentativeURI, AuthorDID sql.NullString
}
type BaselineLabel struct {
	CanonicalKey, Key, Value, Source string
	AppliedAt, ExpiresAt             time.Time
}
type BaselineLabelStore interface {
	LoadTargets(context.Context, int, time.Time) ([]LabelTarget, error)
	ReplaceSnapshot(context.Context, []BaselineLabel, []LabelerEndpoint, []string, int, time.Time) error
	VerifyFresh(context.Context, []LabelerEndpoint, time.Time, time.Duration) error
}
type LabelQuery interface {
	Query(context.Context, LabelerEndpoint, []string, *string) (LabelPage, error)
}

type HTTPLabelQuery struct{ Client *http.Client }

func (q HTTPLabelQuery) Query(ctx context.Context, labeler LabelerEndpoint, subjects []string, cursor *string) (LabelPage, error) {
	if len(subjects) == 0 || len(subjects) > 25 {
		return LabelPage{}, fmt.Errorf("invalid label subject batch")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	u := *labeler.BaseURL
	u.Path = strings.TrimRight(u.Path, "/") + "/xrpc/com.atproto.label.queryLabels"
	values := url.Values{"uriPatterns": subjects, "sources": {labeler.SourceDID}, "limit": {"250"}}
	if cursor != nil {
		values.Set("cursor", *cursor)
	}
	u.RawQuery = values.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return LabelPage{}, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "TheSocialWire-WireWorker/1")
	client := q.Client
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(request)
	if err != nil {
		return LabelPage{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return LabelPage{}, fmt.Errorf("label query status %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 2*1024*1024+1))
	if err != nil {
		return LabelPage{}, err
	}
	if len(body) > 2*1024*1024 {
		return LabelPage{}, fmt.Errorf("label response exceeds byte limit")
	}
	var document LabelPage
	if err = json.Unmarshal(body, &document); err != nil {
		return LabelPage{}, err
	}
	if document.Labels == nil {
		return LabelPage{}, fmt.Errorf("label response missing labels")
	}
	return document, nil
}

// BaselineLabelRefresher does not publish a snapshot until every configured authority
// and every page succeeds. Negation wins equal timestamps, regardless of response order.
type BaselineLabelRefresher struct {
	Store          BaselineLabelStore
	Query          LabelQuery
	Labelers       []LabelerEndpoint
	CandidateLimit int
	MaximumAge     time.Duration
	mu             sync.Mutex
	lastSuccessful time.Time
}

func (r *BaselineLabelRefresher) Refresh(ctx context.Context, at time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.Store == nil || r.Query == nil || len(r.Labelers) == 0 {
		return fmt.Errorf("baseline label refresh dependencies are required")
	}
	if !r.lastSuccessful.IsZero() && at.Sub(r.lastSuccessful) < 300*time.Second {
		return r.Store.VerifyFresh(ctx, r.Labelers, at, r.MaximumAge)
	}
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	targets, err := r.Store.LoadTargets(ctx, r.CandidateLimit, at)
	if err != nil {
		return err
	}
	keysBySubject := map[string]map[string]bool{}
	keySet := map[string]bool{}
	for _, target := range targets {
		keySet[target.CanonicalKey] = true
		for _, subject := range []sql.NullString{target.RepresentativeURI, target.AuthorDID} {
			if subject.Valid && subject.String != "" {
				if keysBySubject[subject.String] == nil {
					keysBySubject[subject.String] = map[string]bool{}
				}
				keysBySubject[subject.String][target.CanonicalKey] = true
			}
		}
	}
	subjects := make([]string, 0, len(keysBySubject))
	for subject := range keysBySubject {
		subjects = append(subjects, subject)
	}
	sort.Strings(subjects)
	var batches [][]string
	for offset := 0; offset < len(subjects); offset += 25 {
		batches = append(batches, subjects[offset:min(offset+25, len(subjects))])
	}
	if len(batches) == 0 {
		batches = [][]string{{"did:example:the-social-wire-label-probe"}}
	}
	var records []LabelRecord
	for _, labeler := range r.Labelers {
		for offset := 0; offset < len(batches); offset += 4 {
			group := batches[offset:min(offset+4, len(batches))]
			results := make([][]LabelRecord, len(group))
			errs := make([]error, len(group))
			var workers sync.WaitGroup
			batchCtx, stop := context.WithCancel(ctx)
			for index, batch := range group {
				workers.Go(func() {
					results[index], errs[index] = r.queryAll(batchCtx, labeler, batch)
					if errs[index] != nil {
						stop()
					}
				})
			}
			workers.Wait()
			stop()
			for index := range group {
				if errs[index] != nil {
					return errs[index]
				}
				records = append(records, results[index]...)
			}
		}
	}
	labels, err := normalizeBaselineLabels(records, r.Labelers, keysBySubject, at)
	if err != nil {
		return err
	}
	keys := make([]string, 0, len(keySet))
	for key := range keySet {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if err = r.Store.ReplaceSnapshot(ctx, labels, r.Labelers, keys, len(targets), at); err != nil {
		return err
	}
	if err = r.Store.VerifyFresh(ctx, r.Labelers, at, r.MaximumAge); err != nil {
		return err
	}
	r.lastSuccessful = at
	return nil
}
func (r *BaselineLabelRefresher) queryAll(ctx context.Context, labeler LabelerEndpoint, subjects []string) ([]LabelRecord, error) {
	var cursor *string
	var records []LabelRecord
	for range 20 {
		page, err := r.Query.Query(ctx, labeler, subjects, cursor)
		if err != nil {
			return nil, err
		}
		records = append(records, page.Labels...)
		if page.Cursor == nil || *page.Cursor == "" {
			return records, nil
		}
		if cursor != nil && *cursor == *page.Cursor {
			return nil, fmt.Errorf("repeated label pagination cursor")
		}
		cursor = page.Cursor
	}
	return nil, fmt.Errorf("label pagination limit exceeded")
}
func normalizeBaselineLabels(records []LabelRecord, labelers []LabelerEndpoint, subjects map[string]map[string]bool, at time.Time) ([]BaselineLabel, error) {
	type identity struct{ Source, Subject, Value string }
	type observation struct {
		Record    LabelRecord
		CreatedAt time.Time
	}
	configured := map[string]bool{}
	for _, labeler := range labelers {
		configured[labeler.SourceDID] = true
	}
	latest := map[identity]observation{}
	for _, record := range records {
		if !configured[record.Source] {
			return nil, fmt.Errorf("unconfigured label authority")
		}
		created, err := time.Parse(time.RFC3339Nano, record.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("invalid label timestamp")
		}
		key := identity{record.Source, record.Subject, record.Value}
		previous, exists := latest[key]
		if exists && (previous.CreatedAt.After(created) || previous.CreatedAt.Equal(created) && (previous.Record.Negated || !record.Negated)) {
			continue
		}
		latest[key] = observation{record, created}
	}
	labels := []BaselineLabel{}
	for _, observed := range latest {
		record := observed.Record
		key, value := labelMapping(record.Value)
		if key == "" || record.Negated {
			continue
		}
		canonicalKeys := subjects[record.Subject]
		if len(canonicalKeys) == 0 {
			continue
		}
		expiry := at.Add(7 * 24 * time.Hour)
		if record.ExpiresAt != nil {
			parsed, err := time.Parse(time.RFC3339Nano, *record.ExpiresAt)
			if err != nil {
				return nil, fmt.Errorf("invalid label expiry")
			}
			if parsed.Before(expiry) {
				expiry = parsed
			}
		}
		if !expiry.After(at) {
			continue
		}
		digest := sha256.Sum256([]byte(record.Subject))
		source := record.Source + "|" + hex.EncodeToString(digest[:]) + "|" + strings.ToLower(record.Value)
		for canonical := range canonicalKeys {
			labels = append(labels, BaselineLabel{canonical, key, value, source, observed.CreatedAt, expiry})
		}
	}
	sort.Slice(labels, func(i, j int) bool {
		a, b := labels[i], labels[j]
		if a.CanonicalKey != b.CanonicalKey {
			return a.CanonicalKey < b.CanonicalKey
		}
		if a.Key != b.Key {
			return a.Key < b.Key
		}
		return a.Source < b.Source
	})
	return labels, nil
}
func labelMapping(value string) (string, string) {
	switch strings.ToLower(value) {
	case "!takedown", "!suspend", "dmca-violation":
		return "moderation", "block"
	case "!hide":
		return "visibility", "exclude"
	case "spam":
		return "moderation", "spam"
	case "adult", "porn", "sexual", "nudity":
		return "moderation", "adult"
	case "graphic", "graphic-media":
		return "moderation", "graphic"
	}
	return "", ""
}

type PostgresBaselineLabelStore struct{ DB *sql.DB }

func (s PostgresBaselineLabelStore) LoadTargets(ctx context.Context, limit int, at time.Time) ([]LabelTarget, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT item.canonical_key,item.representative_uri,item.author_key FROM wire_items item JOIN wire_signal_rollups rollup ON rollup.canonical_key=item.canonical_key WHERE item.eligible=TRUE AND item.expires_at>$1 AND item.source_confidence>=0.25 AND (item.representative_uri IS NOT NULL OR item.author_key IS NOT NULL) AND (rollup.shares_24h>=1 OR rollup.recommendations_24h>=1) ORDER BY rollup.recommendations_24h DESC,rollup.shares_24h DESC,item.canonical_key LIMIT $2`, at, max(1, min(limit, 10000)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	targets := []LabelTarget{}
	for rows.Next() {
		var target LabelTarget
		if err = rows.Scan(&target.CanonicalKey, &target.RepresentativeURI, &target.AuthorDID); err != nil {
			return nil, err
		}
		targets = append(targets, target)
	}
	return targets, rows.Err()
}
func (s PostgresBaselineLabelStore) ReplaceSnapshot(ctx context.Context, labels []BaselineLabel, labelers []LabelerEndpoint, keys []string, count int, at time.Time) error {
	keysJSON, err := json.Marshal(keys)
	if err != nil {
		return err
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `UPDATE wire_label_refresh_state SET is_current=FALSE WHERE is_current=TRUE`); err != nil {
		return err
	}
	for _, labeler := range labelers {
		if _, err = tx.ExecContext(ctx, `DELETE FROM wire_labels WHERE LEFT(source,char_length($1))=$1 AND canonical_key IN(SELECT value FROM jsonb_array_elements_text($2::jsonb))`, labeler.SourceDID+"|", string(keysJSON)); err != nil {
			return err
		}
	}
	for _, label := range labels {
		if _, err = tx.ExecContext(ctx, `INSERT INTO wire_labels(canonical_key,label_key,label_value,source,confidence,applied_at,expires_at) VALUES($1,$2,$3,$4,1,$5,$6) ON CONFLICT(canonical_key,label_key,source) DO UPDATE SET label_value=EXCLUDED.label_value,confidence=EXCLUDED.confidence,applied_at=EXCLUDED.applied_at,expires_at=EXCLUDED.expires_at`, label.CanonicalKey, label.Key, label.Value, label.Source, label.AppliedAt, label.ExpiresAt); err != nil {
			return err
		}
	}
	for _, labeler := range labelers {
		labelCount := 0
		for _, label := range labels {
			if strings.HasPrefix(label.Source, labeler.SourceDID+"|") {
				labelCount++
			}
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO wire_label_refresh_state(source_did,endpoint_host,last_attempted_at,last_successful_at,target_count,label_count,is_current) VALUES($1,$2,$3,$3,$4,$5,TRUE) ON CONFLICT(source_did) DO UPDATE SET endpoint_host=EXCLUDED.endpoint_host,last_attempted_at=EXCLUDED.last_attempted_at,last_successful_at=EXCLUDED.last_successful_at,target_count=EXCLUDED.target_count,label_count=EXCLUDED.label_count,is_current=TRUE`, labeler.SourceDID, labeler.BaseURL.Hostname(), at, count, labelCount); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func (s PostgresBaselineLabelStore) VerifyFresh(ctx context.Context, labelers []LabelerEndpoint, at time.Time, age time.Duration) error {
	for _, labeler := range labelers {
		var valid bool
		if err := s.DB.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_label_refresh_state WHERE source_did=$1 AND is_current=TRUE AND endpoint_host=$2 AND last_successful_at>=$3)`, labeler.SourceDID, labeler.BaseURL.Hostname(), at.Add(-age)).Scan(&valid); err != nil {
			return err
		}
		if !valid {
			return fmt.Errorf("stale baseline label refresh for %s", labeler.SourceDID)
		}
	}
	return nil
}
