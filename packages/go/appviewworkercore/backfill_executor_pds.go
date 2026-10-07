package appviewworkercore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type recoveryIssue struct{ identity, collection, category string }
type recoveryAuthorReport struct {
	results   []BackfillAuthorResult
	issues    []recoveryIssue
	truncated bool
}
type recoveryRateLimiter struct {
	mu       sync.Mutex
	next     time.Time
	interval time.Duration
}

func (r *recoveryRateLimiter) wait(ctx context.Context) error {
	r.mu.Lock()
	now := time.Now()
	start := r.next
	if start.Before(now) {
		start = now
	}
	r.next = start.Add(r.interval)
	r.mu.Unlock()
	return recoveryWait(ctx, max(0, time.Until(start)))
}

type recoveryRateGetter struct {
	base    thinappviewcore.PublicGetter
	limiter *recoveryRateLimiter
}

func (g recoveryRateGetter) Get(ctx context.Context, raw string, headers http.Header, limit, redirects int) (int, http.Header, []byte, error) {
	if err := g.limiter.wait(ctx); err != nil {
		return 0, nil, nil, err
	}
	return g.base.Get(ctx, raw, headers, limit, redirects)
}
func (e *RecoveryEngine) executePDS(ctx context.Context, job BackfillJob, lease *ownedRecoveryLease, progress *recoveryProgressState) (bool, error) {
	maximum := e.MaximumAuthors
	if maximum <= 0 {
		maximum = 500
	}
	cap := e.RecordCapPerAuthor
	if cap <= 0 {
		cap = 2000
	}
	authors := []string{}
	seen := map[string]bool{}
	issues := []recoveryIssue{}
	for _, raw := range job.AuthorDIDs {
		did := strings.TrimSpace(raw)
		if !recoveryDIDValid(did) {
			value := did
			if value == "" {
				value = "<empty>"
			}
			issues = append(issues, recoveryIssue{"scope/" + value, "*", "invalid_did"})
			continue
		}
		if seen[did] {
			issues = append(issues, recoveryIssue{"scope/" + did, "*", "duplicate_did"})
			continue
		}
		seen[did] = true
		authors = append(authors, did)
	}
	if len(job.AuthorDIDs) == 0 {
		issues = append(issues, recoveryIssue{"scope/0", "*", "empty_scope"})
	}
	if len(authors) > maximum {
		issues = append(issues, recoveryIssue{"scope/author_limit", "*", "author_limit_exceeded"})
	}
	if len(issues) > 0 {
		authors = nil
	}
	sort.Strings(authors)
	collections := map[string]bool{}
	for _, c := range job.Collections {
		collections[strings.TrimSpace(c)] = true
	}
	supported, unsupported := []string{}, []string{}
	for c := range collections {
		if c == "site.standard.document" || c == "site.standard.entry" {
			supported = append(supported, c)
		} else {
			unsupported = append(unsupported, c)
			issues = append(issues, recoveryIssue{"unsupported/" + c, c, "unsupported_collection"})
		}
	}
	sort.Strings(supported)
	sort.Strings(unsupported)
	base := e.PDS.HTTP
	if base == nil {
		base = thinappviewcore.PublicHTTP{}
	}
	limiter := &recoveryRateLimiter{interval: time.Second / time.Duration(max(1, job.RateLimit))}
	getter := recoveryRateGetter{base: base, limiter: limiter}
	pds := &thinappviewcore.PDSClient{HTTP: getter, PLCBase: e.PDS.PLCBase}
	concurrency := max(1, min(64, job.MaxConcurrency))
	reports := make(chan recoveryAuthorReport, len(authors))
	jobs := make(chan string)
	var group sync.WaitGroup
	for i := 0; i < min(concurrency, len(authors)); i++ {
		group.Go(func() {
			for did := range jobs {
				report := e.reconcileDiagnosticAuthor(ctx, job, did, supported, unsupported, cap, pds, getter, lease, progress)
				reports <- report
			}
		})
	}
	for _, did := range authors {
		select {
		case jobs <- did:
		case <-ctx.Done():
			close(jobs)
			group.Wait()
			return false, ctx.Err()
		}
	}
	close(jobs)
	group.Wait()
	close(reports)
	results := []BackfillAuthorResult{}
	truncated := false
	for report := range reports {
		results = append(results, report.results...)
		issues = append(issues, report.issues...)
		truncated = truncated || report.truncated
	}
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	sort.Slice(results, func(i, j int) bool {
		if results[i].DID == results[j].DID {
			return results[i].Collection < results[j].Collection
		}
		return results[i].DID < results[j].DID
	})
	if err := lease.mutate(ctx, func(current BackfillJob) (BackfillJob, error) {
		return e.Store.AuthorResults(ctx, current, results, time.Now().UTC())
	}); err != nil {
		return false, err
	}
	progress.failures(len(issues))
	for _, issue := range issues {
		_ = e.Store.RecordFailure(ctx, lease.snapshot(), recoveryIdentityHash(issue.identity), issue.collection, "pds_reconciliation", nil, issue.category, time.Now().UTC())
	}
	return truncated, nil
}
func (e *RecoveryEngine) reconcileDiagnosticAuthor(ctx context.Context, job BackfillJob, did string, collections, unsupported []string, budget int, pds *thinappviewcore.PDSClient, getter thinappviewcore.PublicGetter, lease *ownedRecoveryLease, progress *recoveryProgressState) recoveryAuthorReport {
	report := recoveryAuthorReport{}
	base, err := pds.Resolve(ctx, did)
	if err != nil || base == "" {
		category := "pds_resolution_failed"
		if ctx.Err() != nil {
			category = "cancelled"
		}
		report.issues = append(report.issues, recoveryIssue{did, "*", category})
		report.results = append(report.results, BackfillAuthorResult{DID: did, Collection: "*", Status: "failed", Error: &category})
		return report
	}
	for _, collection := range collections {
		if ctx.Err() != nil {
			return report
		}
		result, issues := e.reconcileDiagnosticCollection(ctx, job, did, base, collection, budget, getter, lease, progress)
		report.results = append(report.results, result)
		report.issues = append(report.issues, issues...)
		report.truncated = report.truncated || result.Truncated
		budget -= result.DiscoveredCount
	}
	for _, collection := range unsupported {
		category := "unsupported_collection"
		report.results = append(report.results, BackfillAuthorResult{DID: did, Collection: collection, Status: "unsupported", Error: &category})
	}
	return report
}
func (e *RecoveryEngine) reconcileDiagnosticCollection(ctx context.Context, job BackfillJob, did, base, collection string, budget int, getter thinappviewcore.PublicGetter, lease *ownedRecoveryLease, progress *recoveryProgressState) (BackfillAuthorResult, []recoveryIssue) {
	result := BackfillAuthorResult{DID: did, Collection: collection}
	issues := []recoveryIssue{}
	kinds := map[string]bool{}
	add := func(category string) {
		kinds[category] = true
		issues = append(issues, recoveryIssue{did + "/" + collection, collection, category})
	}
	if budget <= 0 {
		result.Capped = true
		result.Truncated = true
		add("record_cap_reached")
	}
	cursor := ""
	seen := map[string]bool{}
	reverse := true
	limit := 50
	if collection == "site.standard.document" {
		limit = 10
	}
	for budget > 0 {
		if ctx.Err() != nil {
			add("cancelled")
			break
		}
		params := url.Values{"repo": {did}, "collection": {collection}, "limit": {strconv.Itoa(limit)}}
		if reverse {
			params.Set("reverse", "true")
		}
		if cursor != "" {
			params.Set("cursor", cursor)
		}
		var body []byte
		success := false
		for attempt := 0; attempt <= 3; attempt++ {
			requestCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
			status, headers, data, err := getter.Get(requestCtx, base+"/xrpc/com.atproto.repo.listRecords?"+params.Encode(), http.Header{"Accept": []string{"application/json"}}, 8*1024*1024, 0)
			cancel()
			if err != nil {
				if ctx.Err() != nil {
					add("cancelled")
				} else {
					add("request_failed")
				}
				break
			}
			if len(data) > 8*1024*1024 {
				add("malformed_response")
				break
			}
			if status == 400 && reverse && requiresForward(data) {
				reverse = false
				params.Del("reverse")
				attempt--
				continue
			}
			if status == 429 && attempt < 3 {
				if err = recoveryWait(ctx, repositoryRetryDelay(headers.Get("Retry-After"), attempt+1, time.Now())); err != nil {
					add("cancelled")
					break
				}
				continue
			}
			if status != 200 {
				if status == 429 {
					add("rate_limit_exhausted")
				} else {
					add("request_failed")
				}
				break
			}
			body = data
			success = true
			break
		}
		if !success {
			break
		}
		var page struct {
			Records []struct {
				URI, CID string
				Value    json.RawMessage
			}
			Cursor json.RawMessage
		}
		if json.Unmarshal(body, &page) != nil || page.Records == nil {
			add("malformed_response")
			break
		}
		for _, row := range page.Records {
			if ctx.Err() != nil {
				add("cancelled")
				break
			}
			if result.DiscoveredCount >= budget {
				result.Capped = true
				result.Truncated = true
				add("record_cap_reached")
				break
			}
			result.DiscoveredCount++
			prefix := "at://" + did + "/" + collection + "/"
			key := strings.TrimPrefix(row.URI, prefix)
			var record map[string]any
			if !strings.HasPrefix(row.URI, prefix) || key == "" || strings.Contains(key, "/") || row.CID == "" || json.Unmarshal(row.Value, &record) != nil || record == nil {
				add("malformed_record")
				continue
			}
			if err := e.Projector.Commit(ctx, did, collection, key, row.CID, "create", "", row.Value, time.Time{}, base); err != nil {
				if ctx.Err() != nil {
					add("cancelled")
					break
				}
				add("request_failed")
				continue
			}
			result.ProcessedCount++
			snapshot := progress.record(nil, false)
			if snapshot.Processed%max(1, job.BatchSize) == 0 {
				if err := lease.checkpoint(ctx, snapshot); err != nil {
					add("cancelled")
					break
				}
			}
		}
		if ctx.Err() != nil {
			break
		}
		var next string
		if len(page.Cursor) > 0 && string(page.Cursor) != "null" {
			if json.Unmarshal(page.Cursor, &next) != nil || strings.TrimSpace(next) == "" || len(next) > 4096 {
				add("malformed_response")
				break
			}
		}
		if next != "" && (next == cursor || seen[next] || len(page.Records) == 0) {
			add("malformed_response")
			break
		}
		if next == "" {
			break
		}
		if result.DiscoveredCount >= budget {
			if !result.Capped {
				result.Capped = true
				result.Truncated = true
				add("record_cap_reached")
			}
			break
		}
		seen[next] = true
		cursor = next
	}
	result.FailedCount = max(0, result.DiscoveredCount-result.ProcessedCount)
	categories := []string{}
	for category := range kinds {
		categories = append(categories, category)
	}
	sort.Strings(categories)
	if len(categories) > 0 {
		text := strings.Join(categories, ",")
		result.Error = &text
	}
	switch {
	case kinds["cancelled"]:
		result.Status = "cancelled"
	case len(kinds) == 0 && !result.Truncated && result.FailedCount == 0:
		result.Status = "succeeded"
	case result.ProcessedCount == 0 && !result.Capped:
		result.Status = "failed"
	default:
		result.Status = "partial"
	}
	return result, issues
}
