package wireworkercore

import (
	"context"
	"database/sql"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"golang.org/x/sync/errgroup"
)

type MetadataHTTP interface {
	GetWithURL(context.Context, string, http.Header, int, int) (int, http.Header, []byte, string, error)
}
type EnrichmentHost struct {
	DB                    *sql.DB
	Store                 *MetadataStore
	Config                RuntimeConfig
	HTTP                  MetadataHTTP
	ProfileHTTP           thinappviewcore.PublicGetter
	SchedulingMaintenance bool
	RepairInterval        time.Duration
}

func NewEnrichmentHost(db *sql.DB, pds *thinappviewcore.PDSClient, config RuntimeConfig, environment map[string]string) (*EnrichmentHost, error) {
	enabled := func(key string) bool {
		value := strings.ToLower(environment[key])
		return value == "true" || value == "1"
	}
	interval := 1000
	if parsed, err := strconv.Atoi(environment["WIRE_METADATA_REPAIR_INTERVAL_MS"]); err == nil {
		interval = parsed
	}
	return &EnrichmentHost{DB: db, Store: &MetadataStore{DB: db, SchedulingRead: enabled("WIRE_METADATA_SCHEDULING_READ_ENABLED")}, Config: config, HTTP: thinappviewcore.PublicHTTP{}, ProfileHTTP: thinappviewcore.PublicHTTP{}, SchedulingMaintenance: enabled("WIRE_METADATA_SCHEDULING_MAINTENANCE_ENABLED"), RepairInterval: time.Duration(max(250, min(interval, 60000))) * time.Millisecond}, nil
}
func (h *EnrichmentHost) Startup(ctx context.Context) error { return h.Ready(ctx) }
func (h *EnrichmentHost) Ready(ctx context.Context) error {
	var relation string
	return h.DB.QueryRowContext(ctx, `SELECT 'wire_link_metadata_cache'::regclass::text`).Scan(&relation)
}
func (h *EnrichmentHost) Run(ctx context.Context) error {
	return h.RunWithAuthority(ctx, nil)
}

func (h *EnrichmentHost) RunWithAuthority(ctx context.Context, authority *operationscore.RoleLeaseAuthority) error {
	if authority == nil {
		return ErrMissingAuthority
	}
	group, ctx := errgroup.WithContext(ctx)
	group.Go(func() error { return enrichmentLoop(ctx, h.Config.MetadataIdle, h.metadataBatch) })
	group.Go(func() error { return enrichmentLoop(ctx, h.Config.MetadataIdle, h.profileBatch) })

	group.Go(func() error { return h.repairLoop(ctx, authority) })
	group.Go(func() error {
		var position *metadataPrunePosition
		return maintenanceLoop(ctx, 10*time.Second, 10*time.Second, func(ctx context.Context, at time.Time) (int, error) { return h.disposableBatch(ctx, at, &position) })
	})
	group.Go(func() error { return maintenanceLoop(ctx, 60*time.Second, 15*time.Minute, h.healthBatch) })
	if h.SchedulingMaintenance {
		group.Go(func() error {
			return maintenanceLoop(ctx, 0, 2*time.Second, func(ctx context.Context, at time.Time) (int, error) {
				return 0, h.Store.MaintainScheduling(ctx, authority, at)
			})
		})
	}
	return group.Wait()
}
func enrichmentLoop(ctx context.Context, idle time.Duration, batch func(context.Context, time.Time) (int, error)) error {
	idle = max(250*time.Millisecond, min(idle, 60*time.Second))
	failure := 5 * time.Second
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		count, err := batch(ctx, time.Now().UTC())
		delay := idle
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			delay = failure
			failure = min(60*time.Second, failure*2)
		} else {
			failure = 5 * time.Second
			if count > 0 {
				continue
			}
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
func (h *EnrichmentHost) metadataBatch(ctx context.Context, at time.Time) (int, error) {
	targets, err := h.Store.Claim(ctx, h.Config.MetadataBatch, at)
	if err != nil {
		return 0, err
	}
	group, ctx := errgroup.WithContext(ctx)
	group.SetLimit(max(1, h.Config.MetadataConcurrency))
	for _, target := range targets {
		target := target
		group.Go(func() error { return h.enrich(ctx, target) })
	}
	return len(targets), group.Wait()
}
func (h *EnrichmentHost) enrich(ctx context.Context, target MetadataTarget) error {
	now := time.Now().UTC()
	if target.LeaseUntil.Sub(now)-5*time.Second < 240*time.Second {
		renewed, err := h.Store.Renew(ctx, target, now)
		if err != nil {
			return err
		}
		if renewed == nil {
			return nil
		}
		target = *renewed
	}
	remaining := target.LeaseUntil.Sub(time.Now()) - 5*time.Second
	if remaining <= 0 {
		return nil
	}
	requestCtx, cancel := context.WithTimeout(ctx, min(8*time.Second, remaining))
	defer cancel()
	headers := http.Header{"Accept": {"text/html,application/xhtml+xml;q=0.9"}, "User-Agent": {"TheSocialWire-WireMetadata/1"}}
	if target.ETag != nil {
		headers.Set("If-None-Match", *target.ETag)
	}
	if target.LastModified != nil {
		headers.Set("If-Modified-Since", *target.LastModified)
	}
	status, responseHeaders, body, finalURL, fetchErr := h.HTTP.GetWithURL(requestCtx, target.URL, headers, 512*1024, 3)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	completed := time.Now().UTC()
	if fetchErr == nil && status == 304 {
		etag := metadataFirst(responseHeaders.Get("ETag"), optionalText(target.ETag))
		modified := metadataFirst(responseHeaders.Get("Last-Modified"), optionalText(target.LastModified))
		return h.Store.NotModified(ctx, target, etag, modified, completed)
	}
	negative := status > 0 && status != 429 && status < 500
	if fetchErr == nil && status == 200 {
		content := strings.ToLower(responseHeaders.Get("Content-Type"))
		if strings.HasPrefix(content, "text/html") || strings.HasPrefix(content, "application/xhtml+xml") {
			metadata, err := parseMetadataHTML(body, finalURL)
			if err == nil && metadata != nil {
				metadata.ETag = metadataText(responseHeaders.Get("ETag"))
				metadata.LastModified = metadataText(responseHeaders.Get("Last-Modified"))
				return h.Store.Save(ctx, target, *metadata, completed)
			}
		}
		negative = true
	}
	return h.Store.Failure(ctx, target, negative, completed)
}
