package wireworkercore

import (
	"context"
	"database/sql"
	"net/url"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func object(value any) map[string]any { result, _ := value.(map[string]any); return result }
func isHTTPURL(value string) bool {
	u, err := url.Parse(value)
	return err == nil && u.Hostname() != "" && (strings.ToLower(u.Scheme) == "http" || strings.ToLower(u.Scheme) == "https")
}
func ExternalPostURL(record map[string]any) string {
	embed := object(record["embed"])
	media := object(embed["media"])
	for _, value := range []any{embed["external"], media["external"]} {
		card := object(value)
		for _, key := range []string{"uri", "url"} {
			if text, ok := card[key].(string); ok && isHTTPURL(text) {
				return text
			}
		}
	}
	return structuredURL(record)
}
func structuredURL(value any) string {
	switch value := value.(type) {
	case map[string]any:
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			child := value[key]
			if text, ok := child.(string); ok && (key == "uri" || key == "url") && isHTTPURL(text) {
				return text
			}
			if found := structuredURL(child); found != "" {
				return found
			}
		}
	case []any:
		for _, child := range value {
			if found := structuredURL(child); found != "" {
				return found
			}
		}
	}
	return ""
}
func MentionSubjects(record map[string]any) []string {
	result := map[string]bool{}
	insert := func(raw string) {
		did := strings.ToLower(strings.TrimSpace(raw))
		if strings.HasPrefix(did, "did:") && len([]rune(did)) <= 2048 && strings.IndexFunc(did, unicode.IsSpace) < 0 {
			result[did] = true
		}
	}
	if facets, ok := record["facets"].([]any); ok {
		for _, facet := range facets {
			if features, ok := object(facet)["features"].([]any); ok {
				for _, feature := range features {
					f := object(feature)
					if f["$type"] == "app.bsky.richtext.facet#mention" {
						if did, ok := f["did"].(string); ok {
							insert(did)
						}
					}
				}
			}
		}
	}
	var collect func(any)
	collect = func(value any) {
		switch value := value.(type) {
		case map[string]any:
			if uri, ok := value["uri"].(string); ok && strings.HasPrefix(uri, "at://") {
				insert(strings.Split(strings.TrimPrefix(uri, "at://"), "/")[0])
			}
			for _, child := range value {
				collect(child)
			}
		case []any:
			for _, child := range value {
				collect(child)
			}
		}
	}
	collect(record["embed"])
	subjects := make([]string, 0, len(result))
	for did := range result {
		subjects = append(subjects, did)
	}
	sort.Strings(subjects)
	return subjects
}

type EmbeddedMetadata struct {
	CanonicalURL                 string
	Title, Description, ImageURL *string
}

func embeddedMetadata(record map[string]any, canonical string) *EmbeddedMetadata {
	var find func(any) map[string]any
	find = func(value any) map[string]any {
		switch value := value.(type) {
		case map[string]any:
			if external, ok := value["external"].(map[string]any); ok {
				return external
			}
			keys := make([]string, 0, len(value))
			for key := range value {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			for _, key := range keys {
				if found := find(value[key]); found != nil {
					return found
				}
			}
		case []any:
			for _, child := range value {
				if found := find(child); found != nil {
					return found
				}
			}
		}
		return nil
	}
	external := find(record["embed"])
	if external == nil {
		return nil
	}
	raw := recordString(external, "uri", "url")
	identity := wirecore.Canonicalize(raw)
	if identity == nil || identity.CanonicalURL != canonical {
		return nil
	}
	trim := func(value string) *string {
		if value == "" {
			return nil
		}
		runes := []rune(value)
		if len(runes) > 2000 {
			value = string(runes[:2000])
		}
		return &value
	}
	title, description := trim(recordString(external, "title")), trim(recordString(external, "description"))
	image := trim(recordString(external, "thumb", "image"))
	if image != nil && !isHTTPURL(*image) {
		image = nil
	}
	if title == nil && description == nil && image == nil {
		return nil
	}
	return &EmbeddedMetadata{canonical, title, description, image}
}
func ReplaceItemMentions(ctx context.Context, tx *sql.Tx, source, key, speaker string, subjects []string, occurred, expiry time.Time) error {
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, source); err != nil {
		return err
	}
	var newer bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM wire_item_mentions WHERE source_uri=$1 AND occurred_at>$2)`, source, occurred).Scan(&newer); err != nil {
		return err
	}
	if newer {
		return nil
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM wire_item_mentions WHERE source_uri=$1 AND occurred_at<=$2`, source, occurred); err != nil {
		return err
	}
	for _, subject := range subjects {
		if _, err := tx.ExecContext(ctx, `INSERT INTO wire_item_mentions(source_uri,canonical_key,subject_did,speaker_key_hash,occurred_at,expires_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(source_uri,canonical_key,subject_did) DO UPDATE SET speaker_key_hash=EXCLUDED.speaker_key_hash,occurred_at=EXCLUDED.occurred_at,expires_at=EXCLUDED.expires_at WHERE wire_item_mentions.occurred_at<=EXCLUDED.occurred_at`, source, key, subject, speaker, occurred, expiry); err != nil {
			return err
		}
	}
	return nil
}
func RetractSource(ctx context.Context, tx *sql.Tx, source string, eventTime, at time.Time) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM wire_item_mentions WHERE source_uri=$1 AND occurred_at<=$2`, source, eventTime); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, source); err != nil {
		return err
	}
	for _, query := range []string{`DELETE FROM wire_signal_events WHERE source_uri=$1 AND occurred_at<=$2`, `DELETE FROM wire_article_feedback WHERE source_uri=$1 AND occurred_at<=$2`} {
		if _, err := tx.ExecContext(ctx, query, source, eventTime); err != nil {
			return err
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM wire_follow_edges WHERE source_uri=$1`, source); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM wire_item_aliases alias WHERE alias.alias_key=$1 AND NOT EXISTS(SELECT 1 FROM wire_signal_events signal WHERE signal.source_uri=$1 AND signal.occurred_at>$2)`, source, eventTime); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx, `UPDATE wire_items SET updated_at=$2 WHERE representative_uri=$1`, source, at)
	return err
}
func ApplyPostProjection(ctx context.Context, tx *sql.Tx, hasher *wirecore.ActorHasher, record map[string]any, event InboxEvent, at time.Time) error {
	raw := ExternalPostURL(record)
	identity := wirecore.Canonicalize(raw)
	if raw == "" || !wirecore.TargetKindForURL(raw, false).CanCreateItem() || identity == nil {
		if event.Operation.String == "update" {
			return RetractSource(ctx, tx, event.SourceURI(), event.EventTime, at)
		}
		return nil
	}
	u, _ := url.Parse(identity.CanonicalURL)
	text := recordString(record, "text")
	embedded := embeddedMetadata(record, identity.CanonicalURL)
	title := u.Hostname()
	if first := strings.Split(text, "\n")[0]; first != "" {
		runes := []rune(first)
		title = string(runes[:min(200, len(runes))])
	}
	sourceName := u.Hostname()
	summary := stringPointer(text)
	var image *string
	presentation := "fallback"
	priority := 100
	if embedded != nil {
		if embedded.Title != nil {
			title = *embedded.Title
		}
		if embedded.Description != nil {
			summary = embedded.Description
		}
		image = embedded.ImageURL
		presentation = "embedded_card"
		priority = 200
	}
	var published *time.Time
	if value, err := time.Parse(time.RFC3339Nano, recordString(record, "createdAt")); err == nil {
		published = &value
	}
	quote := strings.Contains(recordString(object(record["embed"]), "$type"), "record")
	provenance, signalKind := "direct_share", "share"
	if quote {
		provenance = "quote"
		signalKind = "quote"
	}
	item := ItemProjection{Identity: *identity, RepresentativeURI: event.SourceURI(), Host: u.Hostname(), SourceName: sourceName, Title: title, Summary: summary, Thumbnail: image, HomepageURL: stringPointer("https://" + u.Host), Language: "und", PublishedAt: published, Provenance: []string{provenance}, Confidence: .6, PresentationSource: presentation, PresentationPriority: priority, SourceText: stringPointer(text), TargetKind: wirecore.ExternalArticle, InspectionURL: raw, RecordsActivity: true}
	if err := UpsertProjectedItem(ctx, tx, item, at); err != nil {
		return err
	}
	if embedded != nil {
		if _, err := tx.ExecContext(ctx, seedEmbeddedMetadataSQL, identity.CanonicalKey, embedded.CanonicalURL, embedded.Title, embedded.Description, embedded.ImageURL, nil, nil, nil, nil, at, hourlyExpiry(at, 7*24*time.Hour)); err != nil {
			return err
		}
	}
	if err := UpsertItemAlias(ctx, tx, event.SourceURI(), "at_uri", identity.CanonicalKey, at); err != nil {
		return err
	}
	if err := UpsertItemAlias(ctx, tx, identity.CanonicalURL, "url", identity.CanonicalKey, at); err != nil {
		return err
	}
	actor, err := hasher.Hash(event.Repository.RepoDID)
	if err != nil {
		return err
	}
	if err = UpsertActiveActor(ctx, tx, actor, at, true); err != nil {
		return err
	}
	if err = InsertProjectedSignal(ctx, tx, event, identity.CanonicalKey, actor, event.SourceURI(), signalKind); err != nil {
		return err
	}
	return ReplaceItemMentions(ctx, tx, event.SourceURI(), identity.CanonicalKey, actor, MentionSubjects(record), event.EventTime, event.EventTime.Add(wirecore.SignalRetention))
}
