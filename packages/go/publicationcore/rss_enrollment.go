package publicationcore

import (
	"context"
	"database/sql"
	"errors"
	"net/url"
	"sync"
)

const maximumRSSConcurrency = 16
const maximumRSSHostConcurrency = 2

type rssEnrollmentKey struct {
	db       *sql.DB
	feed     string
	explicit bool
}

type rssEnrollmentCall struct {
	done     chan struct{}
	count    int
	err      error
	canceled bool
	host     string
}

// Shared by every enroller so concurrent viewers cannot multiply outbound load.
// Dispatch reserves both slots atomically; saturated hosts never occupy workers.
type rssEnrollmentAdmission struct {
	mu      sync.Mutex
	active  int
	hosts   map[string]int
	calls   map[rssEnrollmentKey]*rssEnrollmentCall
	changed chan struct{}
}

func newRSSEnrollmentAdmission() *rssEnrollmentAdmission {
	return &rssEnrollmentAdmission{hosts: map[string]int{}, calls: map[rssEnrollmentKey]*rssEnrollmentCall{}, changed: make(chan struct{})}
}

var sharedRSSAdmission = newRSSEnrollmentAdmission()

func (a *rssEnrollmentAdmission) changes() <-chan struct{} {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.changed
}

// tryStart either joins an existing job or reserves admission for its owner.
// An unavailable host is left queued so dispatch can inspect other hosts.
func (a *rssEnrollmentAdmission) tryStart(key rssEnrollmentKey) (call *rssEnrollmentCall, owner bool, err error) {
	parsed, err := url.Parse(key.feed)
	if err != nil {
		return nil, false, err
	}
	host := parsed.Hostname()
	a.mu.Lock()
	defer a.mu.Unlock()
	if call := a.calls[key]; call != nil {
		return call, false, nil
	}
	if a.active >= maximumRSSConcurrency || a.hosts[host] >= maximumRSSHostConcurrency {
		return nil, false, nil
	}
	call = &rssEnrollmentCall{done: make(chan struct{}), host: host}
	a.calls[key] = call
	a.active++
	a.hosts[host]++
	return call, true, nil
}

func (a *rssEnrollmentAdmission) complete(key rssEnrollmentKey, call *rssEnrollmentCall) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.active--
	a.hosts[call.host]--
	if a.hosts[call.host] == 0 {
		delete(a.hosts, call.host)
	}
	delete(a.calls, key)
	close(call.done)
	close(a.changed)
	a.changed = make(chan struct{})
}

func (a *rssEnrollmentAdmission) finish(ctx context.Context, key rssEnrollmentKey, call *rssEnrollmentCall, owner bool, run func() (int, error)) (int, error) {
	for !owner {
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-call.done:
			if err := ctx.Err(); err != nil {
				return 0, err
			}
			// A caller abort is not a source failure for a still-live subscriber.
			// The old owner has fully unwound and released admission before retry.
			if !call.canceled {
				return call.count, call.err
			}
			var err error
			call, owner, err = a.start(ctx, key)
			if err != nil {
				return 0, err
			}
		}
	}
	defer a.complete(key, call)
	if err := ctx.Err(); err != nil {
		call.err, call.canceled = err, true
		return 0, err
	}
	call.count, call.err = run()
	call.canceled = ctx.Err() != nil
	call.err = errors.Join(call.err, ctx.Err())
	return call.count, call.err
}

func (a *rssEnrollmentAdmission) start(ctx context.Context, key rssEnrollmentKey) (*rssEnrollmentCall, bool, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, false, err
		}
		changed := a.changes()
		call, owner, err := a.tryStart(key)
		if err != nil || call != nil {
			return call, owner, err
		}
		select {
		case <-ctx.Done():
			return nil, false, ctx.Err()
		case <-changed:
		}
	}
}

func (a *rssEnrollmentAdmission) ingest(ctx context.Context, key rssEnrollmentKey, run func() (int, error)) (int, error) {
	call, owner, err := a.start(ctx, key)
	if err != nil {
		return 0, err
	}
	return a.finish(ctx, key, call, owner, run)
}

func (e *Enroller) ingestFeeds(ctx context.Context, feeds []string, explicit bool) (int, error) {
	concurrency := e.RSSConcurrency
	if concurrency <= 0 {
		concurrency = maximumRSSConcurrency
	}
	concurrency = min(concurrency, maximumRSSConcurrency, len(feeds))
	type result struct {
		count int
		err   error
	}
	results := make(chan result, concurrency)
	pending := append([]string{}, feeds...)
	active, total := 0, 0
	errs := []error{}
	for len(pending) > 0 || active > 0 {
		if ctx.Err() != nil {
			pending = nil
		}
		// Observe changes before scanning, so releases during dispatch cannot be
		// missed. Inspect every queued host rather than waiting behind one host.
		changed := sharedRSSAdmission.changes()
		for i := 0; i < len(pending) && active < concurrency; {
			if ctx.Err() != nil {
				pending = nil
				break
			}
			feed := pending[i]
			key := rssEnrollmentKey{db: e.RSS.DB, feed: feed, explicit: explicit}
			call, owner, err := sharedRSSAdmission.tryStart(key)
			if err != nil {
				errs = append(errs, err)
			} else if call == nil {
				i++
				continue
			} else {
				active++
				go func() {
					n, err := sharedRSSAdmission.finish(ctx, key, call, owner, func() (int, error) {
						if explicit {
							return e.RSS.IngestAndWait(ctx, feed)
						}
						return e.RSS.Ingest(ctx, feed)
					})
					results <- result{n, err}
				}()
			}
			pending = append(pending[:i], pending[i+1:]...)
		}
		if len(pending) == 0 && active == 0 {
			break
		}
		var completed result
		if len(pending) == 0 {
			// Cancellation must still join all work this request started.
			completed = <-results
		} else {
			select {
			case completed = <-results:
			case <-changed:
				continue
			case <-ctx.Done():
				continue
			}
		}
		active--
		total += completed.count
		if completed.err != nil {
			errs = append(errs, completed.err)
		}
	}
	return total, errors.Join(append(errs, ctx.Err())...)
}
