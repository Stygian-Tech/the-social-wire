package operationsapi

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
)

func NormalizeBackfillRequest(r BackfillDryRunRequest) (BackfillDryRunRequest, error) {
	invalid := func() (BackfillDryRunRequest, error) {
		return BackfillDryRunRequest{}, HTTPError{400, "Backfill scope or bounds are invalid"}
	}
	if r.SourceMode != "jetstream_replay" && r.SourceMode != "pds_reconciliation" && r.SourceMode != "tap_verified_resync" {
		return invalid()
	}
	if r.BatchSize < 1 || r.BatchSize > 10000 || r.RateLimit < 1 || r.RateLimit > 5000 || r.MaxConcurrency < 1 || r.MaxConcurrency > 16 || r.SourceMode != "pds_reconciliation" && r.MaxConcurrency != 1 || len(r.Collections) == 0 || len(r.Collections) > 16 || len(r.AuthorDIDs) > 500 || r.SourceMode != "jetstream_replay" && len(r.AuthorDIDs) == 0 {
		return invalid()
	}
	if r.SourceMode == "jetstream_replay" && (r.StartCursor == nil || r.EndCursor == nil || *r.StartCursor >= *r.EndCursor) {
		return invalid()
	}
	r.Collections = slices.Clone(r.Collections)
	r.AuthorDIDs = slices.Clone(r.AuthorDIDs)
	seen := map[string]bool{}
	for i, v := range r.Collections {
		v = strings.TrimSpace(v)
		if seen[v] || !(v == "site.standard.document" || v == "site.standard.entry" || r.SourceMode == "jetstream_replay" && v == "app.skyreader.feed.subscription") {
			return invalid()
		}
		seen[v] = true
		r.Collections[i] = v
	}
	seen = map[string]bool{}
	for i, v := range r.AuthorDIDs {
		v = strings.TrimSpace(v)
		if seen[v] || !ValidRecoveryRepositoryDID(v) {
			return invalid()
		}
		seen[v] = true
		r.AuthorDIDs[i] = v
	}
	slices.Sort(r.Collections)
	slices.Sort(r.AuthorDIDs)
	if r.AuthorDIDs == nil {
		r.AuthorDIDs = []string{}
	}
	return r, nil
}
func CanonicalBackfillRequest(r BackfillDryRunRequest) string {
	gap, start, end := "", "", ""
	if r.GapID != nil {
		gap = *r.GapID
	}
	if r.StartCursor != nil {
		start = strconv.FormatInt(*r.StartCursor, 10)
	}
	if r.EndCursor != nil {
		end = strconv.FormatInt(*r.EndCursor, 10)
	}
	collections, authors := slices.Clone(r.Collections), slices.Clone(r.AuthorDIDs)
	slices.Sort(collections)
	slices.Sort(authors)
	return strings.Join([]string{gap, r.SourceMode, start, end, strings.Join(collections, ","), strings.Join(authors, ","), strconv.Itoa(r.BatchSize), strconv.Itoa(r.RateLimit), strconv.Itoa(r.MaxConcurrency)}, "|")
}
func backfillSignature(canonical string, estimate int, expiry int64, environment, secret string) string {
	key := sha256.Sum256([]byte("socialwire:operations:backfill:v1|" + secret))
	mac := hmac.New(sha256.New, key[:])
	mac.Write([]byte(environment + "|" + canonical + "|" + strconv.Itoa(estimate) + "|" + strconv.FormatInt(expiry, 10)))
	return hex.EncodeToString(mac.Sum(nil))
}
func SignBackfillRequest(canonical string, estimate int, until time.Time, environment, secret string) string {
	expiry := until.Unix()
	return "v1." + strconv.FormatInt(expiry, 10) + "." + backfillSignature(canonical, estimate, expiry, environment, secret)
}
func ValidateBackfillFingerprint(fingerprint, canonical string, estimate int, environment, secret string, at time.Time) (time.Time, bool) {
	parts := strings.SplitN(fingerprint, ".", 3)
	if len(parts) != 3 || parts[0] != "v1" || secret == "" {
		return time.Time{}, false
	}
	expiry, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || expiry < at.Unix() {
		return time.Time{}, false
	}
	expected := backfillSignature(canonical, estimate, expiry, environment, secret)
	return time.Unix(expiry, 0), hmac.Equal([]byte(parts[2]), []byte(expected))
}
func backfillOverlaps(job BackfillJob, r BackfillDryRunRequest) bool {
	if (job.Status != "queued" && job.Status != "running" && job.Status != "paused") || job.SourceMode != r.SourceMode || !intersects(job.Collections, r.Collections) {
		return false
	}
	if r.GapID != nil && job.GapID != nil && *r.GapID == *job.GapID {
		return true
	}
	if r.SourceMode == "jetstream_replay" {
		return r.StartCursor != nil && r.EndCursor != nil && job.StartCursor != nil && job.EndCursor != nil && *r.StartCursor < *job.EndCursor && *job.StartCursor < *r.EndCursor
	}
	return intersects(job.AuthorDIDs, r.AuthorDIDs)
}
func intersects(a, b []string) bool {
	for _, v := range a {
		if slices.Contains(b, v) {
			return true
		}
	}
	return false
}
func AssessBackfill(r BackfillDryRunRequest, gap *Gap, jobs []BackfillJob, at time.Time) BackfillDryRunResponse {
	conflicts := []string{}
	estimate := 0
	if r.GapID != nil && gap == nil {
		conflicts = append(conflicts, "The selected gap no longer exists. Refresh the Operations console before continuing.")
	} else {
		if gap != nil {
			if gap.Status == "resolved" || gap.Status == "ignored" {
				conflicts = append(conflicts, "The selected gap is already "+gap.Status+" and does not need a backfill.")
			}
			if r.SourceMode == "jetstream_replay" && (!equalCursor(gap.StartCursor, r.StartCursor) || !equalCursor(gap.EndCursor, r.EndCursor)) {
				conflicts = append(conflicts, "The replay range no longer matches the selected gap. Refresh the dry run.")
			}
			if len(gap.Collections) > 0 && !intersects(gap.Collections, r.Collections) {
				conflicts = append(conflicts, "The selected collections do not intersect the collections observed for this gap.")
			}
		}
		for _, job := range jobs {
			if backfillOverlaps(job, r) {
				conflicts = append(conflicts, "An active backfill already covers this recovery scope.")
				break
			}
		}
		if r.SourceMode == "jetstream_replay" {
			if r.StartCursor != nil && r.EndCursor != nil && *r.EndCursor > *r.StartCursor {
				delta := float64(uint64(*r.EndCursor) - uint64(*r.StartCursor))
				value := delta / 1000000 * 250
				if value >= float64(math.MaxInt/2) {
					estimate = math.MaxInt / 2
				} else {
					estimate = int(value)
				}
			}
		} else {
			estimate = len(r.AuthorDIDs) * 100 * max(1, len(r.Collections))
		}
	}
	duration, method := 0, "unavailable_pinned_tap_resync"
	if r.SourceMode == "jetstream_replay" {
		duration = int(math.Ceil(float64(estimate) / float64(max(1, r.RateLimit))))
		method = "modeled_cursor_density_v1"
	} else if r.SourceMode == "pds_reconciliation" {
		duration = int(math.Ceil((math.Ceil(float64(estimate)/50) + float64(len(r.AuthorDIDs))) / float64(max(1, r.RateLimit))))
		method = "modeled_pds_list_records_50_per_page_plus_author_resolution_v2"
	}
	return BackfillDryRunResponse{EstimatedCount: estimate, EstimatedDurationSeconds: duration, SnapshotEndCursor: r.EndCursor, Conflicts: conflicts, UnresolvedDeletesWarning: r.SourceMode == "pds_reconciliation", RequestFingerprint: CanonicalBackfillRequest(r), ValidUntil: WireTime{at.Add(120 * time.Second)}, Methodology: method, Confidence: "low", EstimateKind: "modeled", Uncertainty: &BackfillEstimateUncertainty{LowerBound: estimate / 2, UpperBound: min(math.MaxInt, estimate*2)}}
}
func equalCursor(a, b *int64) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
func (s *PostgresStore) EstimateBackfill(ctx context.Context, r BackfillDryRunRequest, at time.Time) (BackfillDryRunResponse, error) {
	r, err := NormalizeBackfillRequest(r)
	if err != nil {
		return BackfillDryRunResponse{}, err
	}
	var gap *Gap
	if r.GapID != nil {
		gap, err = s.FetchGap(ctx, *r.GapID)
		if err != nil {
			return BackfillDryRunResponse{}, err
		}
	}
	jobs, err := s.ListBackfills(ctx, "active", 250, nil)
	if err != nil {
		return BackfillDryRunResponse{}, err
	}
	response := AssessBackfill(r, gap, jobs.Items, at)
	if s.FingerprintSecret == "" {
		return BackfillDryRunResponse{}, ErrBackfillFingerprint
	}
	response.RequestFingerprint = SignBackfillRequest(response.RequestFingerprint, response.EstimatedCount, response.ValidUntil.Time, s.Environment, s.FingerprintSecret)
	return response, nil
}
