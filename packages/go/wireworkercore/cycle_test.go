package wireworkercore

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

type cycleStore struct {
	count   int
	commits []GenerationCommit
	loads   []string
	deleted bool
}

func (s *cycleStore) Ping(context.Context) error { return nil }
func (s *cycleStore) EligibleLanguageBuckets(context.Context, int, int, wirecore.RankingConfig, time.Time) ([]string, error) {
	return []string{}, nil
}
func (s *cycleStore) LoadCandidates(_ context.Context, _ string, _ int, ranking wirecore.RankingConfig, at time.Time) ([]wirecore.Candidate, error) {
	s.loads = append(s.loads, ranking.Version)
	items := []wirecore.Candidate{}
	for i := range s.count {
		item := wirecore.NewCandidate(fmt.Sprint(i), fmt.Sprintf("https://%d.example/story", i), fmt.Sprintf("%d.example", i), at)
		yes := true
		item.IsStandardSite = &yes
		item.SourceConfidence = 1
		item.Shares24h = 5
		items = append(items, item)
	}
	return items, nil
}
func (s *cycleStore) Commit(_ context.Context, g GenerationCommit) error {
	s.commits = append(s.commits, g)
	return nil
}
func (s *cycleStore) DeleteExpired(context.Context, time.Time, int) error {
	s.deleted = true
	return nil
}
func TestCycleRequiresLabelsBeforeBuilding(t *testing.T) {
	store := &cycleStore{count: 60}
	config := DefaultCycleConfig()
	config.Mode = "visible"
	cycle := Cycle{Store: store, Config: config}
	if _, err := cycle.Run(context.Background(), time.Now()); err == nil {
		t.Fatal("accepted missing label refresher")
	}
	if len(store.commits) > 0 || len(store.loads) > 0 {
		t.Fatal("ranked before refreshing labels")
	}
	unavailable := errors.New("labels unavailable")
	cycle.RefreshLabels = func(context.Context, time.Time) error { return unavailable }
	if _, err := cycle.Run(context.Background(), time.Now()); !errors.Is(err, unavailable) {
		t.Fatal(err)
	}
}
func TestCycleActivationFloorAndExternalShadow(t *testing.T) {
	for _, count := range []int{49, 50} {
		store := &cycleStore{count: count}
		config := DefaultCycleConfig()
		config.Mode = "api"
		config.ExternalSignalMode = "shadow"
		cycle := Cycle{Store: store, Config: config, RefreshLabels: func(context.Context, time.Time) error { return nil }}
		outcome, err := cycle.Run(context.Background(), time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if len(store.commits) != 2 || store.commits[0].Activate != (count >= 50) || store.commits[1].Activate || outcome.Activated != (count >= 50) {
			t.Fatalf("floor/shadow mismatch %+v %+v", outcome, store.commits)
		}
	}
}
func TestCycleShadowCannotActivate(t *testing.T) {
	store := &cycleStore{count: 80}
	config := DefaultCycleConfig()
	config.Mode = "shadow"
	outcome, err := (Cycle{Store: store, Config: config, RefreshLabels: func(context.Context, time.Time) error { return nil }}).Run(context.Background(), time.Now())
	if err != nil || outcome.Activated || store.commits[0].Activate {
		t.Fatal(outcome, err)
	}
}
func TestRankingSchedulerCadenceAndReadiness(t *testing.T) {
	scheduler := RankingScheduler{}
	at := time.Now()
	first, err := scheduler.Reserve(at)
	if err != nil || first.Token == "" {
		t.Fatal(first, err)
	}
	blocked, err := scheduler.Reserve(at.Add(time.Second))
	if err != nil || blocked.Token != "" {
		t.Fatal("double reservation")
	}
	scheduler.Succeeded("stale-token", at.Add(time.Minute), 5*time.Minute)
	blocked, _ = scheduler.Reserve(at.Add(time.Minute))
	if blocked.Token != "" {
		t.Fatal("stale completion released reservation")
	}
	scheduler.Succeeded(first.Token, at.Add(2*time.Minute), 5*time.Minute)
	wait, _ := scheduler.Reserve(at.Add(2 * time.Minute))
	if wait.Wait != 3*time.Minute {
		t.Fatal("excluded cycle time", wait)
	}
	if !scheduler.IsGenerationReady(at.Add(4*time.Minute), 5*time.Minute) || scheduler.IsGenerationReady(at.Add(6*time.Minute), 5*time.Minute) {
		t.Fatal("readiness did not retain cycle start age")
	}
	second, _ := scheduler.Reserve(at.Add(5 * time.Minute))
	scheduler.Failed(second.Token, at.Add(6*time.Minute))
	if scheduler.IsGenerationReady(at.Add(6*time.Minute), 5*time.Minute) {
		t.Fatal("failure retained readiness")
	}
	wait, _ = scheduler.Reserve(at.Add(6 * time.Minute))
	if wait.Wait != time.Minute {
		t.Fatal("failure retry mismatch", wait)
	}
}
