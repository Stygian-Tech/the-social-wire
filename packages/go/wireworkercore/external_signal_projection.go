package wireworkercore

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type externalTarget struct {
	Value string
	URL   bool
}
type externalRecord struct {
	Kind, Action, Provenance, Retract string
	Targets                           []externalTarget
	AliasesSource                     bool
}

func strongReference(value any) string {
	if object, ok := value.(map[string]any); ok {
		value = object["uri"]
	}
	text, ok := value.(string)
	if !ok {
		return ""
	}
	text = strings.TrimSpace(text)
	if strings.HasPrefix(text, "at://") {
		return text
	}
	return ""
}
func externalURL(value any) string {
	text, ok := value.(string)
	if !ok {
		return ""
	}
	text = strings.TrimSpace(text)
	if isHTTPURL(text) {
		return text
	}
	return ""
}
func normalizeExternal(collection string, record map[string]any) (*externalRecord, error) {
	result := &externalRecord{Kind: "recommendation", Provenance: "margin", AliasesSource: true}
	reference := func(value any) externalTarget { return externalTarget{Value: strongReference(value)} }
	urlTarget := func(value any) externalTarget { return externalTarget{Value: externalURL(value), URL: true} }
	if strings.HasPrefix(collection, "network.cosmik.") {
		result.Provenance = "semble"
	}
	switch collection {
	case "at.margin.note":
		motivation := recordString(record, "motivation")
		valid := false
		for _, m := range []string{"commenting", "highlighting", "bookmarking", "tagging", "describing", "linking", "replying", "editing", "questioning", "assessing"} {
			valid = valid || m == motivation
		}
		target := urlTarget(object(record["target"])["source"])
		if !valid || recordString(record, "createdAt") == "" || target.Value == "" {
			return nil, ErrMalformedDocument
		}
		result.Action = motivation
		result.Targets = []externalTarget{target}
	case "at.margin.reply":
		root := reference(record["root"])
		if recordString(record, "createdAt") == "" || strongReference(record["parent"]) == "" || root.Value == "" {
			return nil, ErrMalformedDocument
		}
		result.Action = "reply"
		result.Targets = []externalTarget{root}
	case "at.margin.like":
		subject := reference(record["subject"])
		if recordString(record, "createdAt") == "" || subject.Value == "" {
			return nil, ErrMalformedDocument
		}
		result.Action = "like"
		result.Kind = "like"
		result.Targets = []externalTarget{subject}
	case "at.margin.collectionItem":
		annotation := reference(record["annotation"])
		if recordString(record, "createdAt") == "" || strongReference(record["collection"]) == "" || annotation.Value == "" {
			return nil, ErrMalformedDocument
		}
		result.Action = "collection_item"
		result.Targets = []externalTarget{annotation}
	case "at.margin.readingRoom":
		featured, ok := record["featuredUris"].([]any)
		if !ok || len(featured) > 12 {
			return nil, ErrMalformedDocument
		}
		for _, value := range featured {
			target := reference(value)
			if target.Value == "" {
				return nil, ErrMalformedDocument
			}
			result.Targets = append(result.Targets, target)
		}
		result.Action = "reading_room"
		result.AliasesSource = false
	case "network.cosmik.card":
		kind := strings.ToUpper(recordString(record, "type"))
		switch kind {
		case "URL":
			target := urlTarget(object(record["content"])["url"])
			if target.Value == "" {
				return nil, ErrMalformedDocument
			}
			result.Action = "card_url"
			result.Targets = []externalTarget{target}
		case "NOTE":
			target := urlTarget(object(record["content"])["url"])
			if target.Value == "" {
				target = reference(record["originalCard"])
				if target.Value == "" {
					target = reference(record["parent"])
				}
				if target.Value == "" {
					return nil, nil
				}
			}
			result.Action = "card_note"
			result.Targets = []externalTarget{target}
		case "":
			return nil, ErrMalformedDocument
		default:
			return nil, nil
		}
	case "network.cosmik.connection":
		for _, value := range []any{record["source"], record["target"]} {
			target := urlTarget(value)
			if target.Value == "" {
				target = reference(value)
			}
			if target.Value == "" {
				return nil, ErrMalformedDocument
			}
			result.Targets = append(result.Targets, target)
		}
		connection := recordString(record, "connectionType")
		if connection == "" {
			connection = "unspecified"
		}
		result.Action = "connection:" + connection
		result.AliasesSource = false
	case "network.cosmik.collectionLink":
		card := reference(record["card"])
		if strongReference(record["collection"]) == "" || card.Value == "" || recordString(record, "addedBy") == "" || recordString(record, "addedAt") == "" {
			return nil, ErrMalformedDocument
		}
		result.Action = "collection_link"
		result.Targets = []externalTarget{card}
	case "network.cosmik.collectionLinkRemoval":
		for _, key := range []string{"collectionLink", "link", "subject"} {
			if uri := strongReference(record[key]); uri != "" {
				result.Retract = uri
				result.Action = "collection_link_removal"
				result.AliasesSource = false
				break
			}
		}
		if result.Retract == "" {
			return nil, ErrMalformedDocument
		}
	default:
		return nil, nil
	}
	seen := map[string]bool{}
	targets := []externalTarget{}
	for _, target := range result.Targets {
		if !seen[target.Value] {
			seen[target.Value] = true
			targets = append(targets, target)
		}
	}
	result.Targets = targets
	result.AliasesSource = result.AliasesSource && len(targets) == 1
	return result, nil
}

type PostgresExternalSignalProjector struct{ Hasher *wirecore.ActorHasher }

func (p PostgresExternalSignalProjector) Apply(ctx context.Context, tx *sql.Tx, record map[string]any, event InboxEvent, at time.Time) error {
	normalized, err := normalizeExternal(event.Collection.String, record)
	if err != nil {
		return err
	}
	if normalized == nil {
		if event.Operation.String == "update" {
			return RetractSource(ctx, tx, event.SourceURI(), event.EventTime, at)
		}
		return nil
	}
	if normalized.Retract != "" {
		return RetractSource(ctx, tx, normalized.Retract, event.EventTime, at)
	}
	keys := []string{}
	seen := map[string]bool{}
	for _, target := range normalized.Targets {
		var key string
		if target.URL {
			key, err = ensureExternalItem(ctx, tx, record, target.Value, event.SourceURI(), at)
		} else {
			key, err = aliasCanonicalKey(ctx, tx, target.Value)
		}
		if err != nil {
			return err
		}
		if key == "" {
			if event.Collection.String != "at.margin.like" {
				return ErrUnresolvedSubject
			}
			continue
		}
		if !seen[key] {
			seen[key] = true
			keys = append(keys, key)
		}
	}
	actor, err := p.Hasher.Hash(event.Repository.RepoDID)
	if err != nil {
		return err
	}
	if len(keys) > 0 {
		if err = UpsertActiveActor(ctx, tx, actor, at, true); err != nil {
			return err
		}
		for _, key := range keys {
			if err = appendItemProvenance(ctx, tx, key, normalized.Kind, at); err != nil {
				return err
			}
		}
	}
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, event.SourceURI()); err != nil {
		return err
	}
	var partition any
	if err = tx.QueryRowContext(ctx, `SELECT ensure_wire_signal_event_partition(($1::timestamptz AT TIME ZONE 'UTC')::date)`, event.EventTime).Scan(&partition); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM wire_signal_events WHERE source_uri=$1 AND occurred_at<=$2`, event.SourceURI(), event.EventTime); err != nil {
		return err
	}
	sort.Strings(keys)
	for _, key := range keys {
		eventKey := fmt.Sprintf("%s:%s:%d:%s", event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence, key)
		transport := fmt.Sprintf("transport:%s:%s:%s:%d:%s", event.Repository.Environment, event.SourceHost, event.CursorKind, event.Sequence, key)
		if _, err = tx.ExecContext(ctx, `INSERT INTO wire_signal_events(event_key,transport_event_key,canonical_key,signal_kind,actor_key_hash,source_uri,source_collection,source_action,occurred_at,expires_at) SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10 WHERE NOT EXISTS(SELECT 1 FROM wire_signal_events WHERE source_uri=$6 AND occurred_at>$9) ON CONFLICT DO NOTHING`, eventKey, transport, key, normalized.Kind, actor, event.SourceURI(), event.Collection.String, normalized.Action, event.EventTime, event.EventTime.Add(wirecore.SignalRetention)); err != nil {
			return err
		}
	}
	if normalized.AliasesSource && len(keys) > 0 {
		return UpsertItemAlias(ctx, tx, event.SourceURI(), "at_uri", keys[0], at)
	}
	return nil
}
func ensureExternalItem(ctx context.Context, tx *sql.Tx, record map[string]any, raw, source string, at time.Time) (string, error) {
	kind := wirecore.TargetKindForURL(raw, false)
	identity := wirecore.Canonicalize(raw)
	if !kind.CanCreateItem() || identity == nil {
		return "", nil
	}
	u, _ := url.Parse(identity.CanonicalURL)
	embedded := embeddedMetadata(record, identity.CanonicalURL)
	text := recordString(record, "text", "note", "description", "value")
	title := recordString(record, "title", "name")
	if title == "" {
		title = strings.Split(text, "\n")[0]
		runes := []rune(title)
		title = string(runes[:min(len(runes), 200)])
	}
	if title == "" {
		title = u.Hostname()
	}
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
	if value, e := time.Parse(time.RFC3339Nano, recordString(record, "publishedAt", "createdAt")); e == nil {
		published = &value
	}
	item := ItemProjection{Identity: *identity, RepresentativeURI: source, Host: u.Hostname(), SourceName: u.Hostname(), Title: title, Summary: summary, Thumbnail: image, HomepageURL: stringPointer("https://" + u.Host), Language: "und", PublishedAt: published, Provenance: []string{"recommendation"}, Confidence: .6, PresentationSource: presentation, PresentationPriority: priority, SourceText: stringPointer(text), TargetKind: kind, InspectionURL: raw, RecordsActivity: true}
	if err := UpsertProjectedItem(ctx, tx, item, at); err != nil {
		return "", err
	}
	if embedded != nil {
		if _, err := tx.ExecContext(ctx, seedEmbeddedMetadataSQL, identity.CanonicalKey, embedded.CanonicalURL, embedded.Title, embedded.Description, embedded.ImageURL, nil, nil, nil, nil, at, hourlyExpiry(at, 7*24*time.Hour)); err != nil {
			return "", err
		}
	}
	if err := UpsertItemAlias(ctx, tx, identity.CanonicalURL, "url", identity.CanonicalKey, at); err != nil {
		return "", err
	}
	return identity.CanonicalKey, nil
}
