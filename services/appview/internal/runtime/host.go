package runtime

import (
	"context"
	"database/sql"
	"errors"
	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/redis/go-redis/v9"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/listcore"
	"github.com/stygian-tech/the-social-wire/packages/go/pdsreadstatecore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/semblecore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/telemetrycore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/topicreadcore"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/config"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/lists"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/podcasts"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/publications"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/readage"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/reader"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/readstate"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/repocache"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/semble"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/topics"
	"github.com/stygian-tech/the-social-wire/services/appview/internal/unreadcounts"
	"net/http"
	"strings"
	"sync"
	"time"
	_ "time/tzdata"
)

type Host struct {
	Config                   config.Config
	DB                       *sql.DB
	Redis                    *redis.Client
	Handler                  http.Handler
	Publications             *publicationcore.Service
	Lists                    *listcore.Runtime
	Podcasts                 *podcasts.Service
	EntryCache               *EntryCache
	Readiness                *Readiness
	Telemetry                *telemetrycore.TelemetryBuffer
	authLife                 *gatewaycore.AuthLifetime
	publicHTTP, internalHTTP *http.Client
	ctx                      context.Context
	cancel                   context.CancelFunc
	wg                       sync.WaitGroup
	closeOnce                sync.Once
}

func NewHost(ctx context.Context, env map[string]string) (*Host, error) {
	c, err := config.Parse(env)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("pgx", c.DatabaseURL)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(c.MaximumConnections)
	db.SetMaxIdleConns(c.MaximumConnections)
	db.SetConnMaxIdleTime(5 * time.Minute)
	work, cancel := context.WithTimeout(ctx, 10*time.Second)
	err = db.PingContext(work)
	cancel()
	if err != nil {
		db.Close()
		return nil, errors.New("AppView PostgreSQL is unavailable")
	}
	h, err := NewHostWithDatabase(ctx, c, db)
	if err != nil {
		db.Close()
	}
	return h, err
}

// NewHostWithDatabase uses an already connected PostgreSQL pool. Close owns it.
func NewHostWithDatabase(ctx context.Context, c config.Config, db *sql.DB) (h *Host, err error) {
	if db == nil {
		return nil, errors.New("AppView requires PostgreSQL")
	}
	process, cancel := context.WithCancel(ctx)
	h = &Host{Config: c, DB: db, ctx: process, cancel: cancel, publicHTTP: gatewaycore.NewPublicHTTPClient(nil), internalHTTP: &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
	defer func() {
		if err != nil {
			h.Close(context.Background())
		}
	}()
	h.publicHTTP.Transport.(*http.Transport).MaxConnsPerHost = 50
	h.authLife = gatewaycore.NewAuthLifetime(process)
	c.Auth.Lifetime = h.authLife
	var commands socialwireredis.Commands
	var cacheClient *socialwireredis.CacheClient
	if c.CacheBackend == "redis" && c.RedisURL != "" {
		opts, e := redis.ParseURL(c.RedisURL)
		if e == nil {
			opts.PoolSize = 8
			opts.DialTimeout = 2 * time.Second
			opts.ReadTimeout = 2 * time.Second
			opts.WriteTimeout = 2 * time.Second
			h.Redis = redis.NewClient(opts)
			commands = socialwireredis.RedisCommands{Client: h.Redis}
			cacheClient = socialwireredis.NewCacheClient(commands)
		}
	}
	projection := thinappviewcore.ProjectionCache{DB: db, Namespace: socialwireredis.NewKeyNamespace(c.Environment, "v1")}
	cacheEnabled := c.CacheBackend == "postgres" || h.Redis != nil
	if c.CacheBackend == "redis" && h.Redis != nil {
		projection.Redis = h.Redis
	}
	baseRepo := &gatewaycore.RepoClient{Client: h.publicHTTP, PLCURL: c.Auth.PLCURL}
	var resolutionRedis redis.Cmdable
	if h.Redis != nil {
		resolutionRedis = h.Redis
	}
	repo := repocache.New(baseRepo, resolutionRedis, c.Environment).RepoClient
	getter := thinappviewcore.PublicHTTP{}
	pds := &thinappviewcore.PDSClient{HTTP: getter, PLCBase: c.Auth.PLCURL}
	h.Publications = publicationcore.NewService(db, repo, h.publicHTTP)
	if cacheEnabled {
		h.Publications.Cache = &publicationcore.CacheStore{Projection: projection}
	}
	if h.Redis != nil {
		h.Publications.Cache.Redis = cacheClient
	}
	var projectionPointer *thinappviewcore.ProjectionCache
	if cacheEnabled {
		projectionPointer = &projection
	}
	h.Publications.Enroller = publicationcore.NewEnroller(db, repo, pds, getter, projectionPointer, c.EnvironmentValues)
	h.Lists = listcore.NewRuntime(db, listcore.RepoReader{Repo: repo}, h.Publications)
	h.Publications.Lists = func(ctx context.Context, auth gatewaycore.AuthContext) (any, error) {
		return h.Lists.Service.Lists(ctx, auth.DID, false)
	}
	authority := &pdsreadstatecore.Store{DB: db, FetchRecord: pds.FetchRecord}
	h.Readiness = NewReadiness(process, authority, c.Environment, func(ctx context.Context, viewer string) error { return h.Publications.Invalidate(ctx, viewer, nil) })
	if c.TelemetryEnabled {
		h.Telemetry = &telemetrycore.TelemetryBuffer{Export: (&telemetrycore.PostgresExporter{DB: db, Environment: c.Environment}).Export}
	}
	if h.Redis != nil {
		h.Redis.AddHook(RedisTelemetryHook{Buffer: h.Telemetry, Service: "appview"})
	}
	projection.LockTelemetry = func(operation, outcome string) {
		if h.Telemetry != nil {
			h.Telemetry.Enqueue(telemetrycore.MetricSample{Name: "socialwire.appview.cache.locks_total", Value: 1, Dimensions: map[string]string{"service": "appview", "operation": operation, "outcome": outcome}})
		}
	}
	configureCachePolicy(c.EnvironmentValues, h.Publications.Cache, &projection)
	if h.Publications.Cache != nil {
		h.Publications.Cache.Projection = projection
	}
	publicMux, protectedMux, discoveryMux := http.NewServeMux(), http.NewServeMux(), http.NewServeMux()
	h.registerHealth(publicMux)
	publications.Routes{Service: h.Publications, Resolver: publicationcore.Resolver{Repo: repo, HTTP: getter}}.Register(protectedMux)
	lists.Routes{Runtime: h.Lists}.Register(protectedMux)
	semble.Routes{Service: semblecore.Service{Transport: semblecore.NewHTTPTransport(c.EnvironmentValues, h.publicHTTP), Reader: semblecore.PublicReader{Repo: repo}}}.Register(protectedMux)
	unreadcounts.Routes{DB: db, Publications: h.Publications, Now: time.Now}.Register(protectedMux)
	readstate.Routes{Store: authority, DB: db, ResolveScopes: h.Publications.ResolveScopes, Invalidate: func(ctx context.Context, viewer string) error { return h.Publications.Invalidate(ctx, viewer, nil) }}.Register(protectedMux)
	readage.Routes{DB: db, Now: time.Now, ResolveScopes: h.Publications.ResolveScopes, Invalidate: h.Publications.Invalidate, RefreshCounts: func(ctx context.Context, viewer string, scopes []appviewcore.PublicationScope, at time.Time) (map[string]int, error) {
		snapshot, e := (publicationcore.CounterStore{DB: db}).Refresh(ctx, viewer, scopes, at)
		return snapshot.Counts, e
	}}.Register(protectedMux)
	var circle *topicreadcore.CircleService
	if c.WireMode != "off" {
		var corpus corpuscore.Store = &corpuscore.PostgreSQLStore{DB: db}
		if c.WireRemote != nil {
			corpus = corpuscore.NewRemoteStore(*c.WireRemote, h.internalHTTP)
		} else if commands != nil && !strings.EqualFold(c.EnvironmentValues["WIRE_SERVING_REDIS_CACHE_ENABLED"], "false") {
			corpus.(*corpuscore.PostgreSQLStore).Cache = corpuscore.NewPayloadCache(commands, c.Environment, "wire-appview-public-payload")
		}
		moderation := topicreadcore.NewModerationService(repo, getter)
		wire, e := topicreadcore.NewWireStore(corpus, c.WireSecret, c.WireMode, moderation.Cache)
		if e != nil {
			return h, e
		}
		selections := &topicreadcore.SelectionProjection{DB: db, Repo: repo}
		finance, e := topicreadcore.NewFinanceStore(db, wire, selections, c.EnvironmentValues)
		if e != nil {
			return h, e
		}
		sports, e := topicreadcore.NewSportsStore(db, wire, selections, c.EnvironmentValues)
		if e != nil {
			return h, e
		}
		if finance != nil {
			if c.FinanceRemote != nil {
				finance.Remote = corpuscore.NewRemoteStore(*c.FinanceRemote, h.internalHTTP)
				finance.Wire, e = topicreadcore.NewWireStore(finance.Remote, finance.Config.CursorSecret, "api", moderation.Cache)
				if e != nil {
					return h, e
				}
			} else if c.WireRemote != nil {
				finance.Remote = corpus
			}
		}
		if sports != nil {
			if c.SportsRemote != nil {
				sports.Remote = corpuscore.NewRemoteStore(*c.SportsRemote, h.internalHTTP)
				sports.Wire, e = topicreadcore.NewWireStore(sports.Remote, sports.Config.CursorSecret, "api", moderation.Cache)
				if e != nil {
					return h, e
				}
			} else if c.WireRemote != nil {
				sports.Remote = corpus
			}
		}
		circle, e = topicreadcore.NewCircleService(db, corpus, wire, moderation, c.EnvironmentValues, commands)
		if e != nil {
			return h, e
		}
		if c.Serves("wire") || c.Serves("finance") || c.Serves("sports") {
			topics.Routes{Wire: wire, WireVisible: c.Serves("wire"), FinanceStore: finance, SportsStore: sports, Moderation: moderation, Telemetry: h.Telemetry, Now: time.Now}.Register(discoveryMux)
		}
		topics.Routes{Circle: circle, Moderation: moderation, Now: time.Now}.Register(protectedMux)
	}
	h.EntryCache = NewEntryCache(process, h.Publications)
	reader.Routes{EntryPage: h.EntryCache.Read, DB: db, Now: time.Now, ListFeed: h.Lists.Feed, RepairFeed: h.Publications.RebuildFeedProjectionFromCachedSidebar, InvalidateRead: func(ctx context.Context, viewer, subject string) error {
		if !cacheEnabled {
			return nil
		}
		return h.invalidateRead(ctx, projection, viewer, subject)
	}, PurgeUnread: func(ctx context.Context, viewer string) error {
		if !cacheEnabled {
			return nil
		}
		return h.invalidateUnread(ctx, projection, viewer, "")
	}, PurgeCircle: func(ctx context.Context, viewer string) error {
		if circle == nil {
			return nil
		}
		return circle.State.Purge(ctx, viewer)
	}}.Register(protectedMux)
	if c.PodcastsEnabled {
		fetcher := podcasts.MediaFetcher{Client: h.publicHTTP}
		s := &podcasts.Service{Store: podcastcore.NewStore(db, c.EnvironmentValues["PODCAST_PRIVATE_STORAGE_KEY"]), Repo: repo, Fetcher: fetcher, BridgeEnabled: strings.EqualFold(c.EnvironmentValues["PODCAST_BRIDGE_ENABLED"], "true"), Now: time.Now, Embedded: &podcasts.EmbeddedArtwork{}, Directory: podcasts.NewDirectory(fetcher)}
		h.Podcasts = s
		assets := &podcasts.Assets{Episode: s.Episode, Show: s.Show, Clip: s.Store.Clip, Fetcher: s.Fetcher, Embedded: s.Embedded, WorkerURL: c.EnvironmentValues["PODCAST_MEDIA_WORKER_URL"], Secret: c.EnvironmentValues["PODCAST_MEDIA_INTERNAL_SECRET"], WorkerClient: h.internalHTTP}
		assets.PublishedRecordMatches = func(ctx context.Context, clip podcastcore.Clip) (bool, error) {
			if clip.PublishedURI == nil {
				return false, nil
			}
			record, e := s.Record(ctx, *clip.PublishedURI)
			return e == nil && podcasts.MatchesClip(record, clip), e
		}
		podcasts.Routes{Service: s, Assets: assets}.Register(protectedMux)
		podcasts.Routes{Service: s, Assets: assets}.RegisterPublic(publicMux)
	}
	protected := gatewaycore.InternalTrustMiddleware(c.InternalSecret, false)(gatewaycore.AuthMiddleware(c.Auth, h.publicHTTP)(h.Readiness.Middleware(protectedMux)))
	discovery := gatewaycore.InternalTrustMiddleware(c.InternalSecret, true)(gatewaycore.AuthMiddleware(c.Auth, h.publicHTTP)(discoveryMux))
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pattern := publicMux.Handler(r); pattern != "" {
			publicMux.ServeHTTP(w, r)
			return
		}
		if _, pattern := discoveryMux.Handler(r); pattern != "" {
			discovery.ServeHTTP(w, r)
			return
		}
		if _, pattern := protectedMux.Handler(r); pattern != "" {
			protected.ServeHTTP(w, r)
			return
		}
		http.NotFound(w, r)
	})
	h.Handler = telemetrycore.HTTPTrace(telemetrycore.HTTPTraceConfig{Service: "appview", Environment: c.Environment, InstanceID: c.InstanceID, Region: c.Region, Telemetry: h.Telemetry}, handler)
	return h, nil
}
func (h *Host) Close(ctx context.Context) error {
	var result error
	h.closeOnce.Do(func() {
		h.cancel()
		if h.Readiness != nil {
			h.Readiness.Close()
		}
		if h.EntryCache != nil {
			h.EntryCache.Close()
		}
		if h.Lists != nil {
			h.Lists.Close()
		}
		if h.Publications != nil {
			h.Publications.Close()
		}
		if h.Podcasts != nil {
			h.Podcasts.Close()
		}
		h.wg.Wait()
		if h.authLife != nil {
			result = errors.Join(result, h.authLife.Close(ctx))
		}
		if h.Telemetry != nil {
			_, e := h.Telemetry.Flush(ctx)
			result = errors.Join(result, e)
		}
		if h.Redis != nil {
			result = errors.Join(result, h.Redis.Close())
		}
		h.publicHTTP.CloseIdleConnections()
		h.internalHTTP.CloseIdleConnections()
		result = errors.Join(result, h.DB.Close())
	})
	return result
}
