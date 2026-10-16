package operationsapi

import (
	"context"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
)

func feedRecoveryRules(conditions []AlertCondition) map[string]AlertCondition {
	rules := map[string]AlertCondition{}
	for _, condition := range conditions {
		rules[condition.Key] = condition
	}
	return rules
}

func TestFeedRecoveryAlertsBudgetsProgressAndResolution(t *testing.T) {
	at := time.Unix(100000, 0)
	old := at.Add(-feedRecoveryProgressWindow)
	health := &feedRecoveryHealth{Sources: []feedRecoverySource{
		{Generation: "appview", State: "paused_budget", AcquiredAt: old},
		{Generation: "wire-replay", State: "replaying", AcquiredAt: old, LastProgressAt: &old, LastSequence: pointer(int64(100)), SealedSequence: pointer(int64(200))},
		{Generation: "wire-live", Wire: true, State: "live", AcquiredAt: old, LastEventAt: &old},
	}, Generation: &feedRecoveryGeneration{GeneratedAt: at, ExpiresAt: at.Add(time.Hour)}}
	rules := feedRecoveryRules(feedRecoveryAlertConditions(health, false, at))
	for _, key := range []string{"replay_budget_paused", "replay_progress_stalled", "wire_event_freshness_delayed"} {
		if !rules["feed_recovery:"+key].Active {
			t.Fatalf("missing condition: %s %+v", key, rules)
		}
	}
	if rules["feed_recovery:wire_event_freshness_delayed"].Severity != "warning" || rules["feed_recovery:wire_generation_delayed"].Active {
		t.Fatal("source lag was hidden by a fresh rerank or treated as proof of a stuck cursor")
	}
	for index := range health.Sources {
		health.Sources[index].State = "snapshot_complete"
	}
	rules = feedRecoveryRules(feedRecoveryAlertConditions(health, false, at))
	for _, key := range []string{"replay_budget_paused", "replay_progress_stalled", "wire_event_freshness_delayed"} {
		if rule, ok := rules["feed_recovery:"+key]; !ok || rule.Active {
			t.Fatalf("recovery did not resolve stable alert key: %s %+v", key, rule)
		}
	}
}

func TestFeedRecoveryAlertsRequireKnownGapAndRespectThreshold(t *testing.T) {
	at := time.Unix(100000, 0)
	for _, fixture := range []struct {
		name         string
		age          time.Duration
		last, sealed *int64
		want         bool
	}{
		{"before boundary", feedRecoveryProgressWindow - time.Second, pointer(int64(100)), pointer(int64(200)), false},
		{"at boundary", feedRecoveryProgressWindow, pointer(int64(100)), pointer(int64(200)), true},
		{"unknown archive tip", time.Hour, pointer(int64(100)), nil, false},
		{"caught up", time.Hour, pointer(int64(200)), pointer(int64(200)), false},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			old := at.Add(-fixture.age)
			health := &feedRecoveryHealth{Sources: []feedRecoverySource{{State: "replaying", AcquiredAt: old, LastProgressAt: &old, LastSequence: fixture.last, SealedSequence: fixture.sealed}}}
			rule := feedRecoveryRules(feedRecoveryAlertConditions(health, false, at))["feed_recovery:replay_progress_stalled"]
			if rule.Active != fixture.want {
				t.Fatalf("stall=%t want %t", rule.Active, fixture.want)
			}
		})
	}
}

func TestFeedRecoveryGenerationAlertEscalatesBeforeServingCeiling(t *testing.T) {
	at := time.Unix(100000, 0)
	for _, fixture := range []struct {
		name     string
		age      time.Duration
		expired  bool
		active   bool
		severity string
	}{
		{"healthy", time.Minute, false, false, "warning"},
		{"stale", 10 * time.Minute, false, true, "warning"},
		{"normal expiry", time.Hour, true, true, "critical"},
		{"six hour ceiling", corpuscore.MaximumWireGenerationAge, false, true, "critical"},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			expires := at.Add(time.Hour)
			if fixture.expired {
				expires = at
			}
			health := &feedRecoveryHealth{Generation: &feedRecoveryGeneration{GeneratedAt: at.Add(-fixture.age), ExpiresAt: expires}}
			rule := feedRecoveryRules(feedRecoveryAlertConditions(health, false, at))["feed_recovery:wire_generation_delayed"]
			if rule.Active != fixture.active || rule.Severity != fixture.severity {
				t.Fatalf("generation condition: %+v", rule)
			}
		})
	}
}

func TestFeedRecoveryEvidenceErrorsDoNotSuppressExistingAlerts(t *testing.T) {
	rules := feedRecoveryRules(EvaluateAlertConditions(AlertEvaluationInput{FeedRecoveryUnavailable: true}, Config{}, time.Now()))
	if !rules["feed_recovery:evidence_unavailable"].Active || !rules["ingestion:authority_evidence_missing"].Active {
		t.Fatal("health lookup failure suppressed existing alert evaluation")
	}
	if _, ok := rules["feed_recovery:replay_budget_paused"]; ok {
		t.Fatal("unavailable evidence falsely resolved a previous budget alert")
	}
	truncated := feedRecoveryRules(feedRecoveryAlertConditions(&feedRecoveryHealth{Truncated: true}, false, time.Now()))
	if !truncated["feed_recovery:source_limit_reached"].Active {
		t.Fatal("source bound was hidden")
	}
	if _, ok := truncated["feed_recovery:replay_budget_paused"]; ok {
		t.Fatal("truncated evidence falsely resolved omitted source")
	}
}

func TestFeedRecoveryJobAndQuarantineRemainVisibleWhileLiveParentIsHealthy(t *testing.T) {
	at := time.Unix(100000, 0)
	old := at.Add(-20 * time.Minute)
	health := &feedRecoveryHealth{
		Sources:      []feedRecoverySource{{Generation: "live-parent", State: "live", AcquiredAt: old, LastStagedAt: &at, JobState: "replaying", JobCreatedAt: &old, JobProgressAt: &old, JobAfter: pointer(int64(100)), JobBefore: pointer(int64(200)), JobLast: pointer(int64(110))}},
		BudgetPaused: 1, Blocked: 1, Expired: 1, Degraded: 1, Quarantined: 1,
	}
	rules := feedRecoveryRules(feedRecoveryAlertConditions(health, false, at))
	keys := []string{"replay_budget_paused", "replay_progress_stalled", "recovery_discontinuity_blocked", "recovery_window_expired", "recovery_controller_degraded", "poison_records_unresolved"}
	for _, key := range keys {
		if !rules["feed_recovery:"+key].Active {
			t.Fatalf("healthy live parent hid %s", key)
		}
	}
	rules = feedRecoveryRules(feedRecoveryAlertConditions(&feedRecoveryHealth{}, false, at))
	for _, key := range keys {
		if rule, ok := rules["feed_recovery:"+key]; !ok || rule.Active {
			t.Fatalf("repaired state did not resolve %s", key)
		}
	}
}

func TestFeedRecoveryHealthLoadsOnlyActivelyLeasedSources(t *testing.T) {
	dsn := os.Getenv("SOCIALWIRE_GO_OPERATIONS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires disposable PostgreSQL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	store, err := NewPostgresStore(tx, "dev")
	if err != nil {
		t.Fatal(err)
	}
	at := time.Now().UTC()
	id, _ := randomUUID()
	for index, duration := range []time.Duration{time.Minute, -time.Second} {
		generation := "feed-health-" + id + strconv.Itoa(index)
		_, err := tx.Exec(ctx, `INSERT INTO appview_ingestion_leases(environment,lease_name,source_generation,owner_id,fencing_token,acquired_at,lease_expires_at,updated_at) VALUES('dev',$1,$1,'fixture',1,$2,$3,$2)`, generation, at.Add(-time.Hour), at.Add(duration))
		if err != nil {
			t.Fatal(err)
		}
		_, err = tx.Exec(ctx, `INSERT INTO ingestion_recovery_controllers(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,status) VALUES('dev',$1,'fixture.invalid','fixture','fixture','jetstream_v2_seq','paused_budget')`, generation)
		if err != nil {
			t.Fatal(err)
		}
		_, err = tx.Exec(ctx, `INSERT INTO ingestion_recovery_jobs(environment,source_generation,id,source_host,stream_nsid,filter_fingerprint,cursor_kind,after_seq,before_seq,status) VALUES('dev',$1,'fixture-job','fixture.invalid','fixture','fixture','jetstream_v2_seq',100,200,'paused_daily')`, generation)
		if err != nil {
			t.Fatal(err)
		}
		_, err = tx.Exec(ctx, `INSERT INTO appview_jetstream_checkpoints(environment,source_generation,source_host,stream_nsid,filter_fingerprint,cursor_kind,replay_state,updated_at) VALUES('dev',$1,'fixture.invalid','fixture','fixture','jetstream_v2_seq','paused_budget',$2)`, generation, at)
		if err != nil {
			t.Fatal(err)
		}
	}
	health, err := store.loadFeedRecoveryHealth(ctx, at)
	if err != nil {
		t.Fatal(err)
	}
	found := 0
	for _, source := range health.Sources {
		if source.Generation == "feed-health-"+id+"0" {
			found++
		}
		if source.Generation == "feed-health-"+id+"1" {
			t.Fatal("inactive old generation was observed")
		}
	}
	if found != 1 {
		t.Fatalf("live source count=%d", found)
	}
	if health.BudgetPaused < 4 {
		t.Fatalf("durable controller/job budgets hidden: %+v", health)
	}
}
