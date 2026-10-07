package topicreadcore

import (
	"database/sql"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialwireredis"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"strings"
)

func NewCircleService(db *sql.DB, corpus corpuscore.Store, wire *WireStore, moderation *ModerationService, environment map[string]string, redis socialwireredis.Commands) (*CircleService, error) {
	mode := strings.ToLower(environment["CIRCLE_FEED_MODE"])
	if mode == "" {
		mode = "off"
	}
	if mode == "off" {
		return nil, nil
	}
	if mode != "api" && mode != "visible" {
		return nil, errors.New("invalid Circle mode")
	}
	if db == nil || corpus == nil || wire == nil || moderation == nil || moderation.Resolver == nil {
		return nil, errors.New("incomplete Circle dependencies")
	}
	actorSecret := strings.TrimSpace(environment["WIRE_ACTOR_HMAC_SECRET"])
	cursorSecret := strings.TrimSpace(environment["CIRCLE_CURSOR_HMAC_SECRET"])
	hasher, err := wirecore.NewActorHasher([]byte(actorSecret))
	if err != nil {
		return nil, err
	}
	cursor, err := wirecore.NewCircleCursorCodec([]byte(cursorSecret))
	if err != nil {
		return nil, err
	}
	state := &CirclePrivateState{DB: db, Hasher: hasher}
	if redis != nil {
		state.Cache = NewCircleCache(redis, environment["APP_ENV"])
	}
	reader := &CircleReader{Moderation: moderation}
	activity := &CircleActivityReader{DB: db, Hasher: hasher}
	if _, remote := corpus.(*corpuscore.RemoteStore); remote {
		activity.DB = nil
		activity.Corpus = corpus
	}
	return &CircleService{Corpus: corpus, Wire: wire, Mode: mode, State: state, Hasher: hasher, Cursor: cursor, Moderation: moderation, Public: reader, Activity: activity, Profiles: reader}, nil
}
