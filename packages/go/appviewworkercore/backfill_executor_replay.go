package appviewworkercore

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/coder/websocket"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

type RecoveryReplayTransport interface {
	Consume(context.Context, string, func([]byte) error) error
}
type WebSocketRecoveryReplayTransport struct{}

func (WebSocketRecoveryReplayTransport) Consume(ctx context.Context, raw string, handle func([]byte) error) error {
	connection, _, err := websocket.Dial(ctx, raw, nil)
	if err != nil {
		return err
	}
	defer connection.CloseNow()
	connection.SetReadLimit(8 * 1024 * 1024)
	for {
		kind, data, err := connection.Read(ctx)
		if err != nil {
			return err
		}
		if kind != websocket.MessageText {
			continue
		}
		if err = handle(data); err != nil {
			return err
		}
	}
}

var errRecoveryReplayComplete = errors.New("recovery replay complete")

type replayProgressMonitor struct {
	mu           sync.Mutex
	lastCursor   int64
	lastProgress time.Time
}

func (m *replayProgressMonitor) observe(cursor int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if cursor > m.lastCursor {
		m.lastCursor = cursor
		m.lastProgress = time.Now()
	}
}
func (e *RecoveryEngine) executeReplay(ctx context.Context, job BackfillJob, lease *ownedRecoveryLease, progress *recoveryProgressState) error {
	if job.EndCursor == nil {
		return errors.New("replay_requires_upper_bound")
	}
	lower := int64(0)
	if job.StartCursor != nil {
		lower = *job.StartCursor
	}
	if job.CheckpointCursor != nil {
		lower = *job.CheckpointCursor
	}
	upper := *job.EndCursor
	if upper < lower {
		return errors.New("replay_requires_upper_bound")
	}
	connectionCursor := max(int64(0), lower-5000000)
	parsed, err := url.Parse(e.RelayURL)
	if err != nil || (parsed.Scheme != "wss" && parsed.Scheme != "ws") || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" {
		return errors.New("invalid_replay_endpoint")
	}
	params := parsed.Query()
	params.Set("cursor", strconv.FormatInt(connectionCursor, 10))
	parsed.RawQuery = params.Encode()
	transport := e.Replay
	if transport == nil {
		transport = WebSocketRecoveryReplayTransport{}
	}
	workCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	monitor := &replayProgressMonitor{lastCursor: connectionCursor, lastProgress: time.Now()}
	authorSet, collectionSet := map[string]bool{}, map[string]bool{}
	for _, did := range job.AuthorDIDs {
		authorSet[did] = true
	}
	for _, collection := range job.Collections {
		collectionSet[collection] = true
	}
	outcome := make(chan error, 2)
	var group sync.WaitGroup
	group.Go(func() {
		outcome <- transport.Consume(workCtx, parsed.String(), func(data []byte) error {
			if err := workCtx.Err(); err != nil {
				return err
			}
			if len(data) > 8*1024*1024 {
				return errors.New("replay_response_too_large")
			}
			var raw map[string]json.RawMessage
			if json.Unmarshal(data, &raw) != nil {
				return nil
			}
			cursor, ok := replayEnvelopeCursor(raw["time_us"])
			if !ok {
				return nil
			}
			monitor.observe(cursor)
			if cursor > upper {
				return errRecoveryReplayComplete
			}
			if cursor <= lower {
				return nil
			}
			var kind, did string
			_ = json.Unmarshal(raw["kind"], &kind)
			_ = json.Unmarshal(raw["did"], &did)
			var commit struct {
				Collection, RKey, Operation, CID string
				Record                           json.RawMessage
			}
			if kind != "commit" || json.Unmarshal(raw["commit"], &commit) != nil || did == "" || commit.Collection == "" || commit.RKey == "" || commit.Operation == "" || (len(authorSet) > 0 && !authorSet[did]) || (len(collectionSet) > 0 && !collectionSet[commit.Collection]) {
				return nil
			}
			record := commit.Record
			if len(record) == 0 {
				record = []byte(`{}`)
			}
			if err := recoveryWait(workCtx, time.Second/time.Duration(max(1, job.RateLimit))); err != nil {
				return err
			}
			err := e.Projector.Commit(workCtx, did, commit.Collection, commit.RKey, commit.CID, commit.Operation, "", record, time.UnixMicro(cursor).UTC(), "")
			if err == nil {
				snapshot := progress.record(&cursor, false)
				if snapshot.Processed%max(1, job.BatchSize) == 0 {
					return lease.checkpoint(workCtx, snapshot)
				}
				return nil
			}
			if workCtx.Err() != nil {
				return workCtx.Err()
			}
			_ = e.Store.RecordFailure(workCtx, lease.snapshot(), recoveryIdentityHash(did+"/"+commit.Collection+"/"+commit.RKey), commit.Collection, commit.Operation, &cursor, recoveryErrorCategory(err), time.Now().UTC())
			snapshot := progress.record(nil, true)
			_ = lease.checkpoint(workCtx, snapshot)
			return err
		})
	})
	group.Go(func() {
		for {
			if err := recoveryWait(workCtx, time.Second); err != nil {
				outcome <- err
				return
			}
			monitor.mu.Lock()
			stalled := time.Since(monitor.lastProgress) >= 30*time.Second
			monitor.mu.Unlock()
			if stalled {
				outcome <- errors.New("replay_stalled")
				return
			}
		}
	})
	first := <-outcome
	cancel()
	group.Wait()
	if errors.Is(first, errRecoveryReplayComplete) {
		return nil
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if first == nil {
		return errors.New("replay_incomplete")
	}
	return first
}
func replayEnvelopeCursor(raw json.RawMessage) (int64, bool) {
	var number json.Number
	if json.Unmarshal(raw, &number) == nil {
		value, err := number.Int64()
		return value, err == nil && value >= 0
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		value, err := strconv.ParseInt(strings.TrimSpace(text), 10, 64)
		return value, err == nil && value >= 0
	}
	return 0, false
}
