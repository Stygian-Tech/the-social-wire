package topicreadcore

import (
	"database/sql"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
	"sync"
	"time"
)

type SportsConfig struct {
	Mode, CursorSecret string
	EventsEnabled      bool
}
type SportsStore struct {
	DB               *sql.DB
	Config           SportsConfig
	Wire             *WireStore
	Selections       *SelectionProjection
	Remote           corpuscore.Store
	Cursor           *TopicCursorCodec
	Hasher           *wirecore.ActorHasher
	mu               sync.Mutex
	importedRevision string
	lastRetention    time.Time
}

func NewSportsStore(db *sql.DB, wire *WireStore, selections *SelectionProjection, env map[string]string) (*SportsStore, error) {
	mode := strings.ToLower(env["SPORTS_FEED_MODE"])
	if mode == "" {
		mode = "off"
	}
	if mode != "off" && mode != "shadow" && mode != "api" && mode != "visible" {
		return nil, errors.New("invalid Sports mode")
	}
	remote, err := corpuscore.RemoteConfigFromEnvironment(map[string]string{"APP_ENV": env["APP_ENV"], "WIRE_CORPUS_EDGE_BASE_URL": env["SPORTS_CORPUS_EDGE_BASE_URL"], "WIRE_CORPUS_EDGE_SERVICE_ID": env["SPORTS_CORPUS_EDGE_SERVICE_ID"], "WIRE_CORPUS_EDGE_HMAC_SECRET": env["SPORTS_CORPUS_EDGE_HMAC_SECRET"]})
	if err != nil {
		return nil, err
	}
	if mode == "off" || mode == "shadow" {
		return nil, nil
	}
	secret, exists := env["SPORTS_CURSOR_HMAC_SECRET"]
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
	store := &SportsStore{DB: db, Wire: wire, Selections: selections, Cursor: cursor, Hasher: hasher, Config: SportsConfig{mode, secret, strings.EqualFold(env["SPORTS_EVENTS_ENABLED"], "true")}}
	if remote != nil {
		store.Remote = corpuscore.NewRemoteStore(*remote, nil)
	}
	return store, nil
}
func (s *SportsStore) serves() bool { return s.Config.Mode == "api" || s.Config.Mode == "visible" }
