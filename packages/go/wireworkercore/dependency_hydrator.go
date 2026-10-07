package wireworkercore

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"
)

type HydrationCounts struct{ Attempted, Verified, Staged, Unavailable, Superseded int }

func (c *HydrationCounts) add(other HydrationCounts) {
	c.Attempted += other.Attempted
	c.Verified += other.Verified
	c.Staged += other.Staged
	c.Unavailable += other.Unavailable
	c.Superseded += other.Superseded
}

type hydrationSubject struct {
	done  chan struct{}
	count int
	err   error
}
type DependencyHydrator struct {
	Store     DependencyRecoveryStore
	Verifier  PublicRecordVerifier
	Processor *PostgresInboxProcessor
	mu        sync.Mutex
	seed      *DependencySeedCursor
	subjects  map[string]*hydrationSubject
	batchMu   sync.Mutex
}

func (h *DependencyHydrator) Hydrate(ctx context.Context, at time.Time, limit int) (HydrationCounts, error) {
	h.batchMu.Lock()
	defer h.batchMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	started := time.Now()
	now := func() time.Time { return at.Add(time.Since(started)) }
	next, err := h.Store.Seed(ctx, h.seed, at)
	if err != nil {
		return HydrationCounts{}, err
	}
	h.seed = next
	counts := HydrationCounts{}
	remaining := max(1, min(16, limit))
	for remaining > 0 {
		jobs, err := h.Store.Claim(ctx, now(), min(2, remaining))
		if err != nil {
			return counts, err
		}
		if len(jobs) == 0 {
			break
		}
		type outcome struct {
			counts HydrationCounts
			err    error
		}
		results := make(chan outcome, len(jobs))
		var group sync.WaitGroup
		for _, job := range jobs {
			group.Go(func() { c, err := h.hydrate(ctx, job, now()); results <- outcome{c, err} })
		}
		group.Wait()
		close(results)
		for result := range results {
			counts.add(result.counts)
			if result.err != nil {
				err = errors.Join(err, result.err)
			}
		}
		if err != nil {
			return counts, err
		}
		remaining -= len(jobs)
	}
	return counts, ctx.Err()
}
func (h *DependencyHydrator) verify(ctx context.Context, uri string, cid *string) (PublicRecordVerification, error) {
	ctx, cancel := context.WithTimeout(ctx, 45*time.Second)
	defer cancel()
	return h.Verifier.Verify(ctx, uri, cid)
}
func (h *DependencyHydrator) hydrate(ctx context.Context, j HydrationJob, at time.Time) (counts HydrationCounts, err error) {
	counts.Attempted = 1
	started := time.Now()
	now := func() time.Time { return at.Add(time.Since(started)) }
	defer func() {
		if err == nil {
			return
		}
		if ctx.Err() != nil {
			err = ctx.Err()
			return
		}
		if postpone := h.Store.Postpone(ctx, j, "dependency_fetch_unavailable", now()); postpone != nil {
			err = errors.Join(err, postpone)
			return
		}
		counts.Unavailable = 1
		err = nil
	}()
	if !j.ExpectedCID.Valid || j.ExpectedCID.String == "" || !j.SubjectURI.Valid || j.SubjectURI.String == "" {
		reason := "missing_original_identity"
		_, err = h.Store.Observe(ctx, j, "unsupported", PublicRecordVerification{}, nil, &reason, now())
		counts.Unavailable = 1
		return
	}
	subject := j.SubjectURI.String
	result, err := h.verify(ctx, j.SourceURI, &j.ExpectedCID.String)
	if err != nil {
		return counts, err
	}
	if result.Status != "verified" {
		reason := "authoritative_record_" + result.Status
		if result.Status == "inactive" {
			reason = "authoritative_repo_inactive"
		}
		_, err = h.Store.Observe(ctx, j, result.Status, result, &subject, &reason, now())
		counts.Unavailable = 1
		return counts, err
	}
	if result.Record == nil || result.Record.URI != j.SourceURI || result.Record.CID != j.ExpectedCID.String {
		return counts, errors.New("verified identity mismatch")
	}
	var original map[string]any
	if err = json.Unmarshal(result.Record.Record, &original); err != nil {
		return counts, err
	}
	if recommendationSubject(original) != subject {
		return counts, errors.New("verified subject mismatch")
	}
	current, err := h.Store.Observe(ctx, j, "verified", result, &subject, nil, now())
	if err != nil {
		return counts, err
	}
	if !current {
		counts.Superseded = 1
		return counts, nil
	}
	counts.Verified = 1
	exists, err := h.Store.HasAlias(ctx, subject, now())
	if err != nil {
		return counts, err
	}
	if !exists {
		counts.Staged, err = h.hydrateSubject(ctx, subject, j, now())
		if err != nil {
			return counts, err
		}
	}
	err = h.Store.Wake(ctx, j, now())
	return counts, err
}
func recommendationSubject(record map[string]any) string {
	text := recordString(record, "document")
	if text == "" {
		text = recordString(record, "subject")
		if text == "" {
			text = recordString(object(record["subject"]), "uri")
		}
	}
	return text
}
func (h *DependencyHydrator) hydrateSubject(ctx context.Context, subject string, j HydrationJob, at time.Time) (int, error) {
	h.mu.Lock()
	if h.subjects == nil {
		h.subjects = map[string]*hydrationSubject{}
	}
	if existing := h.subjects[subject]; existing != nil {
		h.mu.Unlock()
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-existing.done:
			return 0, existing.err
		}
	}
	pending := &hydrationSubject{done: make(chan struct{})}
	h.subjects[subject] = pending
	h.mu.Unlock()
	count, err := h.fetchAndProject(ctx, subject, j, at)
	h.mu.Lock()
	pending.count = count
	pending.err = err
	delete(h.subjects, subject)
	close(pending.done)
	h.mu.Unlock()
	return count, err
}
func (h *DependencyHydrator) fetchAndProject(ctx context.Context, subject string, j HydrationJob, at time.Time) (int, error) {
	started := time.Now()
	now := func() time.Time { return at.Add(time.Since(started)) }
	result, err := h.verify(ctx, subject, nil)
	if err != nil {
		return 0, err
	}
	if result.Status != "verified" || result.Record == nil || result.Record.URI != subject || (result.Record.Collection != "site.standard.document" && result.Record.Collection != "site.standard.entry") {
		return 0, errors.New("subject record unavailable")
	}
	document := *result.Record
	var value map[string]any
	if err = json.Unmarshal(document.Record, &value); err != nil {
		return 0, err
	}
	records := []VerifiedPublicRecord{}
	if site, ok := value["site"].(string); ok && len(site) >= 5 && site[:5] == "at://" {
		publication, err := h.verify(ctx, site, nil)
		if err != nil {
			return 0, err
		}
		if publication.Status != "verified" || publication.Record == nil || publication.Record.URI != site || publication.Record.Collection != "site.standard.publication" {
			return 0, errors.New("publication record unavailable")
		}
		records = append(records, *publication.Record)
	}
	records = append(records, document)
	events, err := h.Store.Stage(ctx, records, j, now())
	if err != nil {
		return 0, err
	}
	for _, event := range events {
		outcome, err := h.Processor.ApplyClaimed(ctx, event, now())
		if err != nil {
			return 0, err
		}
		if outcome != InboxApplied {
			return 0, errors.New("snapshot projection unavailable")
		}
	}
	return len(events), nil
}
func (h *DependencyHydrator) Run(ctx context.Context, snapshots *PostgresInboxProcessor) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		at := time.Now().UTC()
		delay := 5 * time.Second
		claims, err := snapshots.ClaimWork(ctx, at, 2, nil)
		if err == nil {
			for _, event := range claims.Events {
				_, err = snapshots.ApplyClaimed(ctx, event, time.Now().UTC())
				if err != nil {
					break
				}
			}
		}
		var counts HydrationCounts
		if err == nil {
			counts, err = h.Hydrate(ctx, time.Now().UTC(), 16)
		}
		if err == nil {
			_, err = snapshots.DeleteTerminal(ctx, time.Now().UTC(), 250)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			delay = 30 * time.Second
		} else if counts.Attempted > 0 || len(claims.Events) > 0 {
			delay = time.Second
		}
		if err = waitContext(ctx, delay); err != nil {
			return err
		}
	}
}
