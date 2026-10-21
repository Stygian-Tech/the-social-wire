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
	done  chan struct{}
	count int
	err   error
}

// Shared by every enroller so concurrent viewers cannot multiply outbound load.
// A host waiting for admission holds no global slot or database connection.
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

// Preserve per-host order but give each host a turn before dispatching its next
// feed. Otherwise a sorted run of one host can occupy all workers waiting for
// its two admission slots while independent hosts remain queued.
func interleaveRSSFeeds(feeds []string) []string {
	hosts := []string{}
	byHost := map[string][]string{}
	for _, feed := range feeds {
		parsed, _ := url.Parse(feed) // callers supply normalized feed URLs
		host := parsed.Hostname()
		if _, exists := byHost[host]; !exists {
			hosts = append(hosts, host)
		}
		byHost[host] = append(byHost[host], feed)
	}
	ordered := make([]string, 0, len(feeds))
	for len(hosts) > 0 {
		next := hosts[:0]
		for _, host := range hosts {
			ordered = append(ordered, byHost[host][0])
			byHost[host] = byHost[host][1:]
			if len(byHost[host]) > 0 {
				next = append(next, host)
			}
		}
		hosts = next
	}
	return ordered
}

func (a *rssEnrollmentAdmission) acquire(ctx context.Context, host string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if a.active < maximumRSSConcurrency && a.hosts[host] < maximumRSSHostConcurrency {
			a.active++
			a.hosts[host]++
			return nil
		}
		changed := a.changed
		a.mu.Unlock()
		select {
		case <-changed:
		case <-ctx.Done():
		}
		a.mu.Lock()
	}
}

func (a *rssEnrollmentAdmission) release(host string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.active--
	a.hosts[host]--
	if a.hosts[host] == 0 {
		delete(a.hosts, host)
	}
	close(a.changed)
	a.changed = make(chan struct{})
}

func (a *rssEnrollmentAdmission) ingest(ctx context.Context, key rssEnrollmentKey, run func() (int, error)) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	a.mu.Lock()
	if call := a.calls[key]; call != nil {
		a.mu.Unlock()
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-call.done:
			return call.count, errors.Join(call.err, ctx.Err())
		}
	}
	call := &rssEnrollmentCall{done: make(chan struct{})}
	a.calls[key] = call
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		delete(a.calls, key)
		close(call.done)
		a.mu.Unlock()
	}()
	parsed, err := url.Parse(key.feed)
	if err != nil {
		call.err = err
		return 0, err
	}
	host := parsed.Hostname()
	if err := a.acquire(ctx, host); err != nil {
		call.err = err
		return 0, err
	}
	defer a.release(host)
	call.count, call.err = run()
	call.err = errors.Join(call.err, ctx.Err())
	return call.count, call.err
}

func (e *Enroller) ingestFeeds(ctx context.Context, feeds []string, explicit bool) (int, error) {
	concurrency := e.RSSConcurrency
	if concurrency <= 0 {
		concurrency = maximumRSSConcurrency
	}
	concurrency = min(concurrency, maximumRSSConcurrency, len(feeds))
	jobs := make(chan string)
	var wg sync.WaitGroup
	var mu sync.Mutex
	total := 0
	errs := []error{}
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for feed := range jobs {
				n, err := sharedRSSAdmission.ingest(ctx, rssEnrollmentKey{db: e.RSS.DB, feed: feed, explicit: explicit}, func() (int, error) {
					if explicit {
						return e.RSS.IngestAndWait(ctx, feed)
					}
					return e.RSS.Ingest(ctx, feed)
				})
				mu.Lock()
				total += n
				if err != nil {
					errs = append(errs, err)
				}
				mu.Unlock()
			}
		}()
	}
enqueue:
	for _, feed := range interleaveRSSFeeds(feeds) {
		select {
		case <-ctx.Done():
			break enqueue
		case jobs <- feed:
		}
	}
	close(jobs)
	wg.Wait()
	return total, errors.Join(append(errs, ctx.Err())...)
}
