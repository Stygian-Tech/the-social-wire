package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type ItemProjection struct {
	Identity                                                                                   wirecore.CanonicalIdentity
	RepresentativeURI, Host, SourceName, Title, Language, PresentationSource, InspectionURL    string
	PublicationID, AuthorDID, AuthorName, Summary, Thumbnail, HomepageURL, IconURL, SourceText *string
	Topics, Provenance                                                                         []string
	PublishedAt                                                                                *time.Time
	Confidence                                                                                 float64
	PresentationPriority                                                                       int
	TargetKind                                                                                 wirecore.TargetKind
	RecordsActivity                                                                            bool
	SignalTime                                                                                 *time.Time
}

func hourlyExpiry(at time.Time, retention time.Duration) time.Time {
	deadline := at.Add(retention)
	floor := deadline.Truncate(time.Hour)
	if deadline.After(floor) {
		return floor.Add(time.Hour)
	}
	return floor
}
func UpsertProjectedItem(ctx context.Context, tx *sql.Tx, item ItemProjection, at time.Time) error {
	if item.Identity.CanonicalKey == "" || item.Identity.CanonicalURL == "" {
		return fmt.Errorf("missing canonical item identity")
	}
	value := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	evidence := wirecore.ContentEvidence{CanonicalURL: item.InspectionURL, Title: item.Title, Summary: value(item.Summary), SourceText: value(item.SourceText), TopicKeys: item.Topics}
	commercial := wirecore.AssessCommercial(evidence)
	presentation := map[string]any{"metadataSource": item.PresentationSource, "sourcePriority": item.PresentationPriority, "languageSource": "unknown"}
	if item.PresentationSource == "standard_site" && item.Language != "und" {
		presentation["languageSource"] = "standard_site_record"
	}
	if item.Thumbnail != nil {
		presentation["thumbnailSource"] = item.PresentationSource
	}
	if item.HomepageURL != nil {
		presentation["homepageUrl"] = *item.HomepageURL
	}
	if item.IconURL != nil {
		presentation["iconUrl"] = *item.IconURL
	}
	if item.Topics == nil {
		item.Topics = []string{}
	}
	if item.Provenance == nil {
		item.Provenance = []string{}
	}
	topics, err := json.Marshal(item.Topics)
	if err != nil {
		return err
	}
	provenance, err := json.Marshal(item.Provenance)
	if err != nil {
		return err
	}
	snapshot, err := json.Marshal(presentation)
	if err != nil {
		return err
	}
	reasons, err := json.Marshal(commercial.Reasons)
	if err != nil {
		return err
	}
	expiry := hourlyExpiry(at, wirecore.ItemRetention)
	var signalAt *time.Time
	if item.RecordsActivity {
		signalAt = item.SignalTime
		if signalAt == nil {
			signalAt = &at
		}
	}
	_, err = tx.ExecContext(ctx, upsertItemSQL, item.Identity.CanonicalKey, item.Identity.CanonicalURL, item.RepresentativeURI, item.PublicationID, item.AuthorDID, item.Host, item.SourceName, item.AuthorName, item.Title, item.Summary, item.Thumbnail, item.HomepageURL, item.IconURL, item.Language, string(topics), string(snapshot), string(provenance), item.PublishedAt, at, signalAt, item.Confidence, item.TargetKind.CanCreateItem(), string(item.TargetKind), commercial.Score, string(commercial.Classification), string(reasons), expiry)
	if err != nil {
		return err
	}
	if wirecore.IsExplicitAdultContent(evidence) {
		_, err = tx.ExecContext(ctx, `INSERT INTO wire_labels(canonical_key,label_key,label_value,source,confidence,applied_at,expires_at) VALUES($1,'moderation','adult',$2,1,$3,$4) ON CONFLICT(canonical_key,label_key,source) DO UPDATE SET label_value=EXCLUDED.label_value,confidence=EXCLUDED.confidence,applied_at=EXCLUDED.applied_at,expires_at=EXCLUDED.expires_at`, item.Identity.CanonicalKey, wirecore.BaseContentLabelSource, at, expiry)
	}
	return err
}
func UpsertItemAlias(ctx context.Context, tx *sql.Tx, alias, kind, key string, at time.Time) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO wire_item_aliases(alias_key,canonical_key,alias_type,expires_at) VALUES($1,$2,$3,$4) ON CONFLICT(alias_key) DO UPDATE SET canonical_key=EXCLUDED.canonical_key,expires_at=GREATEST(wire_item_aliases.expires_at,EXCLUDED.expires_at) WHERE(wire_item_aliases.canonical_key,wire_item_aliases.expires_at)IS DISTINCT FROM(EXCLUDED.canonical_key,GREATEST(wire_item_aliases.expires_at,EXCLUDED.expires_at))`, alias, key, kind, hourlyExpiry(at, wirecore.ItemRetention))
	return err
}
func UpsertActiveActor(ctx context.Context, tx *sql.Tx, hash string, at time.Time, incrementsActivity bool) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO wire_active_actors(actor_key_hash,first_active_at,last_active_at,public_signal_count,expires_at) VALUES($1,$2,$2,1,$3) ON CONFLICT(actor_key_hash) DO UPDATE SET last_active_at=GREATEST(wire_active_actors.last_active_at,EXCLUDED.last_active_at),public_signal_count=wire_active_actors.public_signal_count+1,expires_at=GREATEST(wire_active_actors.expires_at,EXCLUDED.expires_at) WHERE $4`, hash, at, at.Add(wirecore.ActiveActorRetention), incrementsActivity)
	return err
}
func InsertProjectedSignal(ctx context.Context, tx *sql.Tx, event InboxEvent, key, actorHash, sourceURI, kind string) error {
	eventKey := fmt.Sprintf("%s:%s:%d", event.Repository.Environment, event.Repository.SourceGeneration, event.Sequence)
	transport := fmt.Sprintf("transport:%s:%s:%s:%d", event.Repository.Environment, event.SourceHost, event.CursorKind, event.Sequence)
	// Scan the result so server failures are observed before acknowledgement.
	rows, err := tx.QueryContext(ctx, `SELECT public.wire_insert_signal($1,$2,$3,$4,$5,$6,$7,$8,$9)`, eventKey, transport, key, kind, actorHash, sourceURI, event.Collection, event.EventTime, event.EventTime.Add(wirecore.SignalRetention))
	if err != nil {
		return err
	}
	for rows.Next() {
	}
	err = rows.Err()
	closeErr := rows.Close()
	if err != nil {
		return err
	}
	return closeErr
}
