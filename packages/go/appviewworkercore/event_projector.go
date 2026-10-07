package appviewworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
)

type EventProjectorRuntime struct {
	DB                 *sql.DB
	PDS                *thinappviewcore.PDSClient
	Cache              *thinappviewcore.ProjectionCache
	RSS                *thinappviewcore.RSSIngestion
	Counters           thinappviewcore.CounterStore
	AppliedRetention   time.Duration
	Retention          time.Duration
	WorkerID           string
	ReconcileReadState func(context.Context, string, bool) (bool, error)
	RestoreRepository  func(context.Context, thinappviewcore.RecoveryContext) error
	Now                func() time.Time
}

type projectionOutcomeKey struct{}

func markProjectionMutation(ctx context.Context) {
	if changed, ok := ctx.Value(projectionOutcomeKey{}).(*bool); ok {
		*changed = true
	}
}
func (p *EventProjectorRuntime) ApplyWithOutcome(ctx context.Context, item thinappviewcore.InboxItem) (bool, error) {
	changed := false
	err := p.Apply(context.WithValue(ctx, projectionOutcomeKey{}, &changed), item)
	return changed, err
}

func (p *EventProjectorRuntime) clock() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}
func (p *EventProjectorRuntime) invalidateContent(ctx context.Context, site string) {
	if p.Cache == nil {
		return
	}
	if site == "" {
		_ = p.Cache.InvalidateAll(ctx)
		return
	}
	keys := thinappviewcore.PublicationEquivalenceKeys(site)
	if feed := thinappviewcore.NormalizeFeedURL(site); feed != nil {
		keys = append(keys, *feed, thinappviewcore.RSSPublicationID(*feed))
	}
	if key := thinappviewcore.NormalizePublicationSiteURL(site); key != "" {
		keys = append(keys, key)
	}
	if len(keys) == 0 {
		_ = p.Cache.InvalidateAll(ctx)
		return
	}
	for _, key := range keys {
		_ = p.Cache.InvalidatePublication(ctx, key)
	}
}
func (p *EventProjectorRuntime) Apply(ctx context.Context, item thinappviewcore.InboxItem) error {
	event, err := thinappviewcore.ParseProjectionEvent(item.Payload, item.Sequence, item.EventKind, item.RepoDID)
	if err != nil {
		return err
	}
	switch event.Kind {
	case "commit":
		commit := event.Commit
		if item.Collection != nil && *item.Collection != commit.Collection || item.Operation != nil && *item.Operation != commit.Operation || item.RepoRev != nil && *item.RepoRev != commit.RepoRev || item.RecordKey != nil && *item.RecordKey != commit.RKey || item.RecordCID != nil && (commit.CID == nil || *item.RecordCID != *commit.CID) {
			return thinappviewcore.ErrMetadataMismatch
		}
		cid := ""
		if commit.CID != nil {
			cid = *commit.CID
		}
		return p.Commit(ctx, event.DID, commit.Collection, commit.RKey, cid, commit.Operation, commit.RepoRev, commit.RecordJSON, event.EventTime, "")
	case "identity":
		if p.PDS != nil {
			p.PDS.Invalidate(event.DID)
		}
		return nil
	case "account":
		if p.PDS != nil {
			p.PDS.Invalidate(event.DID)
		}
		if !event.Account.Active || event.Account.Status != "active" {
			if _, err := (thinappviewcore.ContentStore{DB: p.DB}).DeleteAuthor(ctx, event.DID); err != nil {
				return err
			}
			if p.Cache != nil {
				_ = p.Cache.InvalidateAll(ctx)
			}
		}
		return nil
	case "sync":
		if p.RestoreRepository == nil {
			return errors.New("repository reconciliation unavailable")
		}
		recovery := thinappviewcore.RecoveryContext{Environment: item.Environment, SourceGeneration: item.SourceGeneration, Sequence: item.Sequence, RepoDID: item.RepoDID, WorkerID: p.WorkerID, LeaseToken: item.LeaseToken}
		if err := p.RestoreRepository(ctx, recovery); err != nil {
			return err
		}
		if p.ReconcileReadState == nil {
			return errors.New("read-state reconciliation unavailable")
		}
		if _, err := p.ReconcileReadState(ctx, event.DID, false); err != nil {
			return err
		}
		return (thinappviewcore.InboxStore{DB: p.DB}).Reconciled(ctx, item, p.WorkerID, event.Sync.RepoRev, p.clock().Add(p.appliedRetention()), p.clock())
	default:
		return thinappviewcore.ErrInvalidEnvelope
	}
}
func (p *EventProjectorRuntime) Commit(ctx context.Context, did, collection, key, cid, operation, rev string, raw []byte, eventAt time.Time, pds string) error {
	if collection == "app.thesocialwire.readState" {
		if key != "self" {
			return nil
		}
		if p.ReconcileReadState == nil {
			return errors.New("read-state reconciliation unavailable")
		}
		changed, err := p.ReconcileReadState(ctx, did, false)
		if err == nil && changed {
			markProjectionMutation(ctx)
		}
		return err
	}
	record := map[string]any{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &record); err != nil {
			return err
		}
	}
	if collection == "app.thesocialwire.finance.selection" || collection == "app.thesocialwire.sports.selection" {
		topic := "finance"
		if strings.Contains(collection, ".sports.") {
			topic = "sports"
		}
		mutation := thinappviewcore.ParseSelectionMutation(topic, did, key, operation, record, eventAt, rev)
		if mutation == nil {
			return nil
		}
		err := (thinappviewcore.SelectionStore{DB: p.DB}).Apply(ctx, *mutation)
		if err == nil {
			markProjectionMutation(ctx)
		}
		return err
	}
	if collection == thinappviewcore.RSSSubscriptionCollection {
		feed, ok := record["feedUrl"].(string)
		source, _ := record["sourceType"].(string)
		if ok && (source == "" || strings.EqualFold(strings.TrimSpace(source), "rss")) && operation != "delete" && p.RSS != nil {
			if normalized := thinappviewcore.NormalizeFeedURL(feed); normalized != nil {
				if _, err := p.RSS.Ingest(ctx, *normalized); err != nil {
					return err
				}
				markProjectionMutation(ctx)
			}
		}
		if p.Cache != nil {
			markProjectionMutation(ctx)
			_ = p.Cache.InvalidateViewer(ctx, did)
			if normalized := thinappviewcore.NormalizeFeedURL(feed); normalized != nil {
				p.invalidateContent(ctx, thinappviewcore.RSSPublicationID(*normalized))
				p.invalidateContent(ctx, *normalized)
				if operation != "delete" {
					_ = p.Cache.WarmRSSFirstPage(ctx, *normalized, p.clock())
				}
			}
		}
		return nil
	}
	if collection == "site.standard.graph.subscription" {
		if p.Cache != nil {
			markProjectionMutation(ctx)
			_ = p.Cache.InvalidateViewer(ctx, did)
			if publication, ok := record["publication"].(string); ok && operation != "delete" {
				p.invalidateContent(ctx, strings.TrimSpace(publication))
			}
		}
		return nil
	}
	supported := false
	for _, allowed := range []string{"site.standard.document", "site.standard.entry", "com.standard.document", "com.standard.entry"} {
		supported = supported || collection == allowed
	}
	if !supported {
		return nil
	}
	uri := "at://" + did + "/" + collection + "/" + key
	site := thinappviewcore.PublicationSiteField(record)
	content := thinappviewcore.ContentStore{DB: p.DB}
	now := p.clock()
	if operation == "delete" {
		if err := content.Delete(ctx, uri); err != nil {
			return err
		}
		if err := p.Counters.Dirty(ctx, did, site, now); err != nil {
			return err
		}
		p.invalidateContent(ctx, site)
		markProjectionMutation(ctx)
		return nil
	}
	if pds == "" && p.PDS != nil {
		resolved, err := p.PDS.Resolve(ctx, did)
		if err == nil {
			pds = resolved
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	render := thinappviewcore.ExtractRenderFields(record, did, pds, now)
	if render.ArticleURL == nil && site != "" && p.PDS != nil && strings.HasPrefix(site, "at://") {
		parts := strings.Split(strings.TrimPrefix(site, "at://"), "/")
		if len(parts) == 3 {
			_, _, publication, err := p.PDS.FetchRecord(ctx, parts[0], parts[1], parts[2], nil)
			if err == nil {
				var value map[string]any
				if json.Unmarshal(publication, &value) == nil {
					base := ""
					for _, key := range []string{"url", "siteUrl", "site", "homepage"} {
						if candidate, ok := value[key].(string); ok {
							base = thinappviewcore.NormalizePublicationSiteURL(candidate)
							if base != "" {
								break
							}
						}
					}
					if article := thinappviewcore.ArticleURL(record, base); article != "" {
						render.ArticleURL = &article
					}
				}
			}
		}
	}
	created, err := time.Parse(time.RFC3339Nano, render.PublishedAt)
	if err != nil {
		created = now
	}
	retention := p.Retention
	if retention <= 0 {
		retention = 30 * 24 * time.Hour
	}
	var publication *string
	if site != "" {
		publication = &site
	}
	item := thinappviewcore.IndexedContentItem{URI: uri, CID: cid, AuthorDID: did, Collection: collection, CreatedAt: created, IndexedAt: now, ExpiresAt: now.Add(retention), PublicationSite: publication, Render: render}
	existed, err := content.Exists(ctx, uri)
	if err != nil {
		return err
	}
	if err := content.Upsert(ctx, item); err != nil {
		return err
	}
	if existed {
		err = p.Counters.Dirty(ctx, did, site, now)
	} else {
		err = p.Counters.Increment(ctx, item, now)
	}
	if err != nil {
		return err
	}
	p.invalidateContent(ctx, site)
	markProjectionMutation(ctx)
	return nil
}

func (p *EventProjectorRuntime) appliedRetention() time.Duration {
	if p.AppliedRetention > 0 {
		return p.AppliedRetention
	}
	return 7 * 24 * time.Hour
}
