package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/url"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type MetadataTarget struct {
	Key, URL           string
	ETag, LastModified *string
	LeaseUntil         time.Time
}
type LinkMetadata struct {
	URL                                                                                       string
	Title, Description, ImageURL, SiteName, AuthorName, IconURL, ETag, LastModified, Language *string
	PublishedAt                                                                               *time.Time
	ProductOffer, Affiliate                                                                   bool
}
type MetadataStore struct {
	DB             *sql.DB
	SchedulingRead bool
	mu             sync.Mutex
	priorityAfter  time.Time
}

func scanMetadataTargets(rows *sql.Rows) ([]MetadataTarget, error) {
	defer rows.Close()
	var targets []MetadataTarget
	for rows.Next() {
		var t MetadataTarget
		if err := rows.Scan(&t.Key, &t.URL, &t.ETag, &t.LastModified, &t.LeaseUntil); err != nil {
			return nil, err
		}
		targets = append(targets, t)
	}
	return targets, rows.Err()
}
func (s *MetadataStore) Claim(ctx context.Context, limit int, at time.Time) ([]MetadataTarget, error) {
	limit = max(1, min(limit, 250))
	priority := max(1, limit*3/4)
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SET LOCAL statement_timeout='2s'`); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, `SET LOCAL lock_timeout='500ms'`); err != nil {
		return nil, err
	}
	var targets []MetadataTarget
	s.mu.Lock()
	runPriority := !at.Before(s.priorityAfter)
	if runPriority {
		s.priorityAfter = at.Add(5 * time.Second)
	}
	s.mu.Unlock()
	if runPriority {
		if _, err := tx.ExecContext(ctx, `SAVEPOINT metadata_priority_claim`); err != nil {
			return nil, err
		}
		query := metadataPrioritySQL
		if s.SchedulingRead {
			ready, err := s.schedulingReady(ctx, tx)
			if err != nil {
				return nil, err
			}
			if ready {
				query = metadataScheduledPrioritySQL
			}
		}
		rows, e := tx.QueryContext(ctx, query, at, priority, at.Add(300*time.Second))
		if e == nil {
			targets, e = scanMetadataTargets(rows)
		}
		if e != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			var pg *pgconn.PgError
			if !errors.As(e, &pg) || (pg.Code != "57014" && pg.Code != "55P03") {
				return nil, e
			}
			if _, err := tx.ExecContext(ctx, `ROLLBACK TO SAVEPOINT metadata_priority_claim`); err != nil {
				return nil, err
			}
			targets = nil
		} else {
			s.mu.Lock()
			s.priorityAfter = time.Time{}
			s.mu.Unlock()
		}
		if _, err := tx.ExecContext(ctx, `RELEASE SAVEPOINT metadata_priority_claim`); err != nil {
			return nil, err
		}
	}
	if remaining := limit - len(targets); remaining > 0 {
		rows, err := tx.QueryContext(ctx, metadataGeneralSQL, at, remaining, at.Add(300*time.Second))
		if err != nil {
			return nil, err
		}
		general, err := scanMetadataTargets(rows)
		if err != nil {
			return nil, err
		}
		targets = append(targets, general...)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return targets, nil
}
func (s *MetadataStore) Renew(ctx context.Context, t MetadataTarget, at time.Time) (*MetadataTarget, error) {
	rows, err := s.DB.QueryContext(ctx, metadataRenewSQL, at.Add(300*time.Second), at, t.Key, t.LeaseUntil)
	if err != nil {
		return nil, err
	}
	targets, err := scanMetadataTargets(rows)
	if err != nil || len(targets) == 0 {
		return nil, err
	}
	return &targets[0], nil
}
func (s *MetadataStore) NotModified(ctx context.Context, t MetadataTarget, etag, lastModified *string, at time.Time) error {
	_, err := s.DB.ExecContext(ctx, metadataNotModifiedSQL, etag, lastModified, at, at.Add(24*time.Hour), at.Add(7*24*time.Hour), t.Key, t.LeaseUntil)
	return err
}
func (s *MetadataStore) Failure(ctx context.Context, t MetadataTarget, negative bool, at time.Time) error {
	status := "retry"
	delay := 900 * time.Second
	if negative {
		status = "negative"
		delay = 6 * time.Hour
	}
	_, err := s.DB.ExecContext(ctx, metadataFailureSQL, status, at.Add(delay), at, t.Key, t.LeaseUntil)
	return err
}
func (s *MetadataStore) Save(ctx context.Context, t MetadataTarget, m LinkMetadata, at time.Time) error {
	language := validatedPageLanguage(m.Language, m.Title, m.Description)
	kind := wirecore.TargetKindForURL(m.URL, false)
	commercial := wirecore.AssessCommercial(wirecore.ContentEvidence{CanonicalURL: m.URL, Title: optionalText(m.Title), Summary: optionalText(m.Description), HasProductOfferSchema: m.ProductOffer, HasAffiliateDisclosure: m.Affiliate})
	reasons, err := json.Marshal(commercial.Reasons)
	if err != nil {
		return err
	}
	var homepage *string
	if parsed, err := url.Parse(m.URL); err == nil && parsed.Hostname() != "" {
		parsed.Path = ""
		parsed.RawPath = ""
		parsed.RawQuery = ""
		parsed.Fragment = ""
		homepage = stringPointer(parsed.String())
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var accepted string
	err = tx.QueryRowContext(ctx, metadataCacheUpdateSQL, m.URL, m.Title, m.Description, m.ImageURL, m.SiteName, m.AuthorName, m.PublishedAt, m.IconURL, m.ETag, m.LastModified, language, at, at.Add(24*time.Hour), at.Add(7*24*time.Hour), t.Key, t.LeaseUntil).Scan(&accepted)
	if errors.Is(err, sql.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, metadataItemUpdateSQL, m.Title, m.Description, m.ImageURL, m.SiteName, m.AuthorName, m.PublishedAt, language, homepage, m.IconURL, kind.CanCreateItem(), string(kind), commercial.Score, string(commercial.Classification), string(reasons), at, t.Key); err != nil {
		return err
	}
	return tx.Commit()
}
func optionalText(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
