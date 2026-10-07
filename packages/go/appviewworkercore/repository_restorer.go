package appviewworkercore

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type RepositoryRestorer struct {
	Snapshots               RepositorySnapshotSource
	DB                      *sql.DB
	PDS                     *thinappviewcore.PDSClient
	Projector               *EventProjectorRuntime
	RecordBudget            int
	MaximumRateLimitRetries int
}

func (r RepositoryRestorer) Restore(ctx context.Context, scope thinappviewcore.RecoveryContext) error {
	if r.PDS == nil || r.Projector == nil {
		return errors.New("repository restorer configuration unavailable")
	}
	store := thinappviewcore.RecoveryStore{DB: r.DB}
	state, err := store.Load(ctx, scope)
	if err != nil {
		return err
	}
	if state.Completed {
		return r.finalize(ctx, scope.RepoDID)
	}
	pds, err := r.PDS.Resolve(ctx, scope.RepoDID)
	if err != nil {
		return err
	}
	if pds == "" {
		return errors.New("repository PDS unavailable")
	}
	if state.PDSBase != nil && *state.PDSBase != pds {
		token, err := newSnapshotToken()
		if err != nil {
			return err
		}
		state = thinappviewcore.RecoveryState{SnapshotID: token, StartedAt: state.StartedAt, Collections: map[string]thinappviewcore.RecoveryCollection{}}
	}
	state.PDSBase = &pds
	state, err = store.Save(ctx, scope, state, nil, false)
	if err != nil {
		return err
	}
	if state.SnapshotMode == signedSnapshotMode {
		return r.restoreSignedSnapshot(ctx, store, scope, state)
	}
	budget := r.RecordBudget
	if budget <= 0 {
		budget = 200
	}
	// Recovery checkpoints yield small successful slices before the restore deadline.
	// Diagnostic backfills retain their independently configured record budget.
	budget = min(200, budget)
	observedThisSlice := 0
	pagesThisSlice := 0
	pageBudget := min(20, (budget+9)/10)
	for _, collection := range []string{"site.standard.document", "site.standard.entry"} {
		previous := state.Collections[collection]
		if previous.Complete {
			continue
		}
		if previous.SeenCursors == nil {
			previous.SeenCursors = []string{}
		}
		reverse := true
		limit := 50
		if collection == "site.standard.document" {
			limit = 10
		}
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			if observedThisSlice >= budget || pagesThisSlice >= pageBudget {
				return r.yield(ctx, store, scope)
			}
			// Leave the next request's timeout plus DB headroom before starting another
			// page. Only saved progress can yield; request failures remain failures.
			if deadline, ok := ctx.Deadline(); ok && pagesThisSlice > 0 && time.Until(deadline) < 21*time.Second {
				return r.yield(ctx, store, scope)
			}
			params := url.Values{"repo": []string{scope.RepoDID}, "collection": []string{collection}, "limit": []string{strconv.Itoa(limit)}}
			if reverse {
				params.Set("reverse", "true")
			}
			if previous.Cursor != nil {
				params.Set("cursor", *previous.Cursor)
			}
			client := r.PDS.HTTP
			if client == nil {
				client = thinappviewcore.PublicHTTP{}
			}
			var body []byte
			attempt := 0
			for {
				requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
				status, headers, data, err := client.Get(requestCtx, pds+"/xrpc/com.atproto.repo.listRecords?"+params.Encode(), http.Header{"Accept": []string{"application/json"}}, 8*1024*1024, 0)
				cancel()
				if err != nil {
					return err
				}
				if status == 400 && reverse && requiresForward(data) {
					reverse = false
					params.Del("reverse")
					continue
				}
				// Some PDS document serializers reject pages larger than one record.
				// Retry a single record before switching to a signed snapshot.
				if status == 400 && collection == "site.standard.document" && limit > 1 && documentPageInvalidRequest(data) {
					limit = 1
					reverse = false
					params.Del("reverse")
					params.Set("limit", "1")
					continue
				}
				if status == 429 && attempt < r.MaximumRateLimitRetries {
					attempt++
					delay := repositoryRetryDelay(headers.Get("Retry-After"), attempt, time.Now())
					timer := time.NewTimer(delay)
					select {
					case <-ctx.Done():
						timer.Stop()
						return ctx.Err()
					case <-timer.C:
					}
					continue
				}
				if status == 400 && collection == "site.standard.document" && limit == 1 && documentPageInvalidRequest(data) {
					fallback := r
					fallback.RecordBudget = budget - observedThisSlice
					return fallback.restoreSignedSnapshot(ctx, store, scope, state)
				}
				if status != 200 {
					return fmt.Errorf("repository listRecords status %d", status)
				}
				body = data
				break
			}
			var page struct {
				Records []struct {
					URI   string          `json:"uri"`
					CID   string          `json:"cid"`
					Value json.RawMessage `json:"value"`
				} `json:"records"`
				Cursor json.RawMessage `json:"cursor"`
			}
			if err := json.Unmarshal(body, &page); err != nil {
				return err
			}
			if page.Records == nil || len(page.Records) > limit {
				return errors.New("malformed repository page")
			}
			var next *string
			if len(page.Cursor) > 0 && string(page.Cursor) != "null" {
				var cursor string
				if err := json.Unmarshal(page.Cursor, &cursor); err != nil {
					return errors.New("malformed repository cursor")
				}
				if cursor != "" {
					next = &cursor
				}
			}
			if next != nil {
				if len(page.Records) == 0 {
					return errors.New("empty repository page with continuation")
				}
				for _, seen := range previous.SeenCursors {
					if seen == *next {
						fallback := r
						fallback.RecordBudget = budget - observedThisSlice
						return fallback.restoreSignedSnapshot(ctx, store, scope, state)
					}
				}
				previous.SeenCursors = append(previous.SeenCursors, *next)
				if len(previous.SeenCursors) > 10000 {
					return errors.New("repository page limit exceeded")
				}
			}
			uris := []string{}
			for _, record := range page.Records {
				expected := "at://" + scope.RepoDID + "/" + collection + "/"
				if !strings.HasPrefix(record.URI, expected) || strings.Contains(strings.TrimPrefix(record.URI, expected), "/") || strings.TrimPrefix(record.URI, expected) == "" || record.CID == "" || len(record.Value) == 0 || record.Value[0] != '{' {
					return errors.New("malformed repository record")
				}
				if err := r.Projector.Commit(ctx, scope.RepoDID, collection, strings.TrimPrefix(record.URI, expected), record.CID, "create", "", record.Value, time.Now(), pds); err != nil {
					return err
				}
				uris = append(uris, record.URI)
			}
			previous.Cursor = next
			previous.Complete = next == nil
			previous.ObservedCount += len(page.Records)
			previous.IndexedCount += len(page.Records)
			observedThisSlice += len(page.Records)
			state.Collections[collection] = previous
			state, err = store.Save(ctx, scope, state, uris, false)
			if err != nil {
				return err
			}
			pagesThisSlice++
			if previous.Complete {
				break
			}
			if observedThisSlice >= budget || pagesThisSlice >= pageBudget {
				return r.yield(ctx, store, scope)
			}
		}
	}
	state.Completed = true
	state, err = store.Save(ctx, scope, state, nil, true)
	if err != nil {
		return err
	}
	if !state.Completed {
		return r.yield(ctx, store, scope)
	}
	return r.finalize(ctx, scope.RepoDID)
}

// A completed content snapshot still needs its derived counters and caches finalized.
// Retrying this step must never refetch the PDS or repeat snapshot pruning.
func (r RepositoryRestorer) finalize(ctx context.Context, did string) error {
	if err := r.Projector.Counters.DirtyAuthor(ctx, did, time.Now()); err != nil {
		return err
	}
	if r.Projector.Cache != nil {
		return r.Projector.Cache.InvalidateAll(ctx)
	}
	return nil
}
func (r RepositoryRestorer) yield(ctx context.Context, store thinappviewcore.RecoveryStore, scope thinappviewcore.RecoveryContext) error {
	if err := store.Yield(ctx, scope); err != nil {
		return err
	}
	return thinappviewcore.ErrRecoveryYielded
}
func requiresForward(body []byte) bool {
	var value map[string]any
	if json.Unmarshal(body, &value) != nil {
		return false
	}
	message, _ := value["message"].(string)
	message = strings.ToLower(message)
	return strings.Contains(message, "reverse") && (strings.Contains(message, "unsupported") || strings.Contains(message, "not supported") || strings.Contains(message, "unknown") || strings.Contains(message, "invalid"))
}
func documentPageInvalidRequest(body []byte) bool {
	var value struct {
		Error string `json:"error"`
	}
	return json.Unmarshal(body, &value) == nil && strings.EqualFold(value.Error, "InvalidRequest")
}

func newSnapshotToken() (string, error) {
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(token[:]), nil
}

func repositoryRetryDelay(value string, attempt int, at time.Time) time.Duration {
	if seconds, err := strconv.ParseFloat(strings.TrimSpace(value), 64); err == nil && seconds >= 0 {
		return time.Duration(min(60, seconds) * float64(time.Second))
	}
	if date, err := http.ParseTime(value); err == nil {
		return min(time.Minute, max(0, date.Sub(at)))
	}
	return time.Duration(min(30, 1<<min(max(0, attempt-1), 5))) * time.Second
}
