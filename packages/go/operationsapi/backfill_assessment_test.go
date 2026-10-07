package operationsapi

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5/pgxpool"
	"math"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

func validAssessmentRequest() BackfillDryRunRequest {
	return BackfillDryRunRequest{SourceMode: "pds_reconciliation", Collections: []string{"site.standard.document"}, AuthorDIDs: []string{"did:plc:abcdefghijklmnopqrstuvwx"}, BatchSize: 100, RateLimit: 10, MaxConcurrency: 2}
}
func TestRecoveryScopeValidationAndSignedAssessment(t *testing.T) {
	for _, did := range []string{"did:plc:abcdefghijklmnopqrstuvwx", "did:web:stygiantech.dev:people:sam%20test"} {
		if !ValidRecoveryRepositoryDID(did) {
			t.Fatal(did)
		}
	}
	for _, did := range []string{"did:web:skyreader.rss", "did:web:localhost", "did:web:127.0.0.1", "did:web:001.002.003.004", "did:web:10.1.2.3", "did:web:foo.internal", "did:web:example.com", "did:web:foo.dev:", "did:web:foo.dev:bad%2", "did:web:foo.dev:bad/slash", "did:web:foo.dev%3A80", "did:plc:ABCDEFGHIJKLMNOPQRSTUVWX", "did:plc:abcdefghijklmnopqrstuvw0", "did:web:foo.dev "} {
		if ValidRecoveryRepositoryDID(did) {
			t.Fatal("unsafe repository accepted", did)
		}
	}
	r := validAssessmentRequest()
	r.AuthorDIDs = append(r.AuthorDIDs, " "+r.AuthorDIDs[0])
	if _, err := NormalizeBackfillRequest(r); err == nil {
		t.Fatal("duplicate normalized author accepted")
	}
	r = validAssessmentRequest()
	r.SourceMode = "jetstream_replay"
	start, end := int64(0), int64(1000000)
	r.StartCursor = &start
	r.EndCursor = &end
	if _, err := NormalizeBackfillRequest(r); err == nil {
		t.Fatal("unsupported replay concurrency")
	}
	r.MaxConcurrency = 1
	response := AssessBackfill(r, nil, nil, time.Unix(1000, 0))
	if response.EstimatedCount != 250 || response.EstimatedDurationSeconds != 25 || response.Methodology != "modeled_cursor_density_v1" {
		t.Fatal(response)
	}
	start, end = math.MinInt64, math.MaxInt64
	response = AssessBackfill(r, nil, nil, time.Unix(1000, 0))
	if response.EstimatedCount < 0 || response.Uncertainty.UpperBound < 0 {
		t.Fatal("overflow", response)
	}
	r = validAssessmentRequest()
	response = AssessBackfill(r, nil, nil, time.Unix(1000, 0))
	if response.EstimatedCount != 100 || response.EstimatedDurationSeconds != 1 || !response.UnresolvedDeletesWarning || response.ValidUntil.Unix() != 1120 {
		t.Fatal(response)
	}
	canonical := CanonicalBackfillRequest(r)
	fingerprint := SignBackfillRequest(canonical, 100, time.Unix(2000000000, 0), "dev", "fixture-secret")
	if fingerprint != "v1.2000000000.21695ff0d9bb092a6bb6924dc4893864277db45bc63f6dbac8de3590331f76e5" {
		t.Fatal(fingerprint)
	}
	if _, ok := ValidateBackfillFingerprint(fingerprint, canonical, 100, "dev", "fixture-secret", time.Unix(2000000000, 999999999)); !ok {
		t.Fatal("inclusive second expiry rejected")
	}
	for _, check := range []struct {
		canonical   string
		count       int
		env, secret string
		at          int64
	}{{canonical, 100, "prod", "fixture-secret", 1000}, {canonical, 101, "dev", "fixture-secret", 1000}, {canonical + "changed", 100, "dev", "fixture-secret", 1000}, {canonical, 100, "dev", "wrong", 1000}, {canonical, 100, "dev", "fixture-secret", 2000000001}} {
		if _, ok := ValidateBackfillFingerprint(fingerprint, check.canonical, check.count, check.env, check.secret, time.Unix(check.at, 0)); ok {
			t.Fatal("changed/expired token accepted")
		}
	}
}
func TestRecoveryEnqueueLocksScopeAndReplaysAfterExpiry(t *testing.T) {
	url := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	store, _ := NewPostgresStore(pool, "dev")
	store.FingerprintSecret = "fixture-secret"
	gapID, _ := randomUUID()
	at := time.Now().UTC().Truncate(time.Microsecond)
	_, err = pool.Exec(ctx, `INSERT INTO appview_ingestion_gaps(environment,id,source,reason,status,collections,detected_at,updated_at,version) VALUES('dev',$1,'fixture','fixture','confirmed','["site.standard.document"]'::jsonb,$2,$2,0)`, gapID, at)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for _, table := range []string{"operations_audit_events", "operations_idempotency_records"} {
			_, _ = pool.Exec(c, `DELETE FROM `+table+` WHERE environment='dev' AND target_id IN (SELECT id FROM appview_backfill_jobs WHERE environment='dev' AND gap_id=$1)`, gapID)
		}
		_, _ = pool.Exec(c, `UPDATE appview_ingestion_gaps SET backfill_job_id=NULL WHERE environment='dev' AND id=$1`, gapID)
		_, _ = pool.Exec(c, `DELETE FROM appview_backfill_jobs WHERE environment='dev' AND gap_id=$1`, gapID)
		_, _ = pool.Exec(c, `DELETE FROM appview_ingestion_gaps WHERE environment='dev' AND id=$1`, gapID)
	})
	r := validAssessmentRequest()
	r.GapID = &gapID
	author := strings.ReplaceAll(gapID, "-", "")[:24]
	for digit, letter := range map[string]string{"0": "a", "1": "b", "8": "c", "9": "d"} {
		author = strings.ReplaceAll(author, digit, letter)
	}
	r.AuthorDIDs = []string{"did:plc:" + author}
	assessment, err := store.EstimateBackfill(ctx, r, at)
	if err != nil || len(assessment.Conflicts) != 0 {
		t.Fatal(assessment, err)
	}
	version := 0
	request := CreateBackfillRequest{DryRun: r, ExpectedEstimate: assessment.EstimatedCount, ExpectedGapVersion: &version, RequestFingerprint: assessment.RequestFingerprint, IdempotencyKey: "create-" + gapID}
	jobs := make([]BackfillJob, 2)
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i := range jobs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			jobs[i], errs[i] = store.CreateBackfill(ctx, request, "did:plc:fixture", nil, at)
		}()
	}
	wg.Wait()
	for i := range jobs {
		if errs[i] != nil || jobs[i].Status != "queued" || jobs[i].VerificationStatus != "required" {
			t.Fatal(jobs[i], errs[i])
		}
	}
	if jobs[0].ID != jobs[1].ID {
		t.Fatal("duplicate recovery jobs")
	}
	gap, err := store.FetchGap(ctx, gapID)
	if err != nil || gap.Status != "backfill_queued" || gap.Version != 1 || gap.BackfillJobID == nil || *gap.BackfillJobID != jobs[0].ID {
		t.Fatal(gap, err)
	}
	replay, err := store.CreateBackfill(ctx, request, "did:plc:fixture", nil, at.Add(time.Hour))
	if err != nil || replay.ID != jobs[0].ID {
		t.Fatal("expired exact replay rejected", replay, err)
	}
	conflict := request
	conflict.IdempotencyKey = "overlap-" + gapID
	conflict.DryRun.GapID = nil
	conflict.ExpectedGapVersion = nil
	conflict.RequestFingerprint = SignBackfillRequest(CanonicalBackfillRequest(conflict.DryRun), conflict.ExpectedEstimate, at.Add(time.Minute), "dev", "fixture-secret")
	if _, err = store.CreateBackfill(ctx, conflict, "did:plc:fixture", nil, at); !errors.Is(err, ErrOverlappingBackfill) {
		t.Fatal("overlap accepted", err)
	}
	var audits int
	if err = pool.QueryRow(ctx, `SELECT count(*) FROM operations_audit_events WHERE environment='dev' AND target_id=$1`, jobs[0].ID).Scan(&audits); err != nil || audits != 3 {
		t.Fatal("audit/replay not durable", audits, err)
	}
}
