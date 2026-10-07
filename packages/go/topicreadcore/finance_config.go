package topicreadcore

import (
	"database/sql"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
	"sync"
	"time"
)

type FinanceConfig struct {
	Mode            string
	CursorSecret    string
	Widgets, Rights bool
	OpenFIGIKey     *string
	Policy          financecore.ProviderPolicy
}
type FinanceStore struct {
	DB               *sql.DB
	Config           FinanceConfig
	Wire             *WireStore
	Selections       *SelectionProjection
	Remote           corpuscore.Store
	Cursor           *TopicCursorCodec
	Hasher           *wirecore.ActorHasher
	mu               sync.Mutex
	importedRevision string
	lastRetention    time.Time
	lastSearch       time.Time
	searchCache      map[string]financeSearchEntry
	Provider         FinanceSearchProvider
}
type financeSearchEntry struct {
	At    time.Time
	Items []financecore.Instrument
}

func NewFinanceStore(db *sql.DB, wire *WireStore, selections *SelectionProjection, env map[string]string) (*FinanceStore, error) {
	mode := strings.ToLower(env["FINANCE_FEED_MODE"])
	if mode == "" {
		mode = "off"
	}
	if mode != "off" && mode != "shadow" && mode != "api" && mode != "visible" {
		return nil, errors.New("invalid Finance mode")
	}
	if mode == "off" || mode == "shadow" {
		return nil, nil
	}
	secret, exists := env["FINANCE_CURSOR_HMAC_SECRET"]
	if !exists {
		secret = env["WIRE_CURSOR_HMAC_SECRET"]
	}
	cursor, err := NewTopicCursorCodec([]byte(secret))
	if err != nil {
		return nil, err
	}
	hasher, err := wirecore.NewActorHasher([]byte(secret))
	if err != nil {
		return nil, err
	}
	if db == nil || wire == nil || selections == nil {
		return nil, ErrUnavailable
	}
	config := FinanceConfig{Mode: mode, CursorSecret: secret, Widgets: strings.EqualFold(env["FINANCE_WIDGETS_ENABLED"], "true"), Rights: strings.EqualFold(env["FINANCE_CATALOG_RIGHTS_CONFIRMED"], "true"), Policy: financecore.NewProviderPolicy(env)}
	if key, ok := env["OPENFIGI_API_KEY"]; ok {
		config.OpenFIGIKey = &key
	}
	remoteConfig, err := corpuscore.RemoteConfigFromEnvironment(map[string]string{"APP_ENV": env["APP_ENV"], "WIRE_CORPUS_EDGE_BASE_URL": env["FINANCE_CORPUS_EDGE_BASE_URL"], "WIRE_CORPUS_EDGE_SERVICE_ID": env["FINANCE_CORPUS_EDGE_SERVICE_ID"], "WIRE_CORPUS_EDGE_HMAC_SECRET": env["FINANCE_CORPUS_EDGE_HMAC_SECRET"]})
	if err != nil {
		return nil, err
	}
	s := &FinanceStore{DB: db, Config: config, Wire: wire, Selections: selections, Cursor: cursor, Hasher: hasher, searchCache: map[string]financeSearchEntry{}, Provider: NewOpenFIGISearch(config.OpenFIGIKey, nil)}
	if remoteConfig != nil {
		s.Remote = corpuscore.NewRemoteStore(*remoteConfig, nil)
	}
	return s, nil
}
func (s *FinanceStore) serves() bool {
	return (s.Config.Mode == "api" || s.Config.Mode == "visible") && s.Config.Rights
}
