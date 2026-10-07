package wireworkercore

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestRollupExactWindowAndSignalExpiryBoundaries(t *testing.T) {
	for _, incremental := range []bool{false, true} {
		t.Run(fmt.Sprint(incremental), func(t *testing.T) {
			f := newRollupFixture(t, incremental)
			expires := f.at.Add(14 * 24 * time.Hour)
			keys := []string{f.item("hour"), f.item("day"), f.item("week"), f.item("expiry"), f.item("deleted")}
			for i, age := range []time.Duration{time.Hour, 24 * time.Hour, 7 * 24 * time.Hour} {
				f.signal(keys[i], fmt.Sprint(i), f.at.Add(-age), expires)
			}
			f.signal(keys[3], "expiry", f.at, f.at.Add(time.Second))
			f.signal(keys[4], "delete", f.at, expires)
			f.refresh(f.at)
			f.requireCount(keys[0], "signals_1h", 1)
			f.requireCount(keys[1], "signals_24h", 1)
			f.requireCount(keys[2], "signals_7d", 1)
			f.exec(`DELETE FROM wire_signal_events WHERE canonical_key=$1`, keys[4])
			later := f.at.Add(time.Second)
			f.refresh(later)
			f.requireCount(keys[0], "signals_1h", 0)
			f.requireCount(keys[0], "signals_24h", 1)
			f.requireCount(keys[1], "signals_24h", 0)
			f.requireCount(keys[1], "signals_7d", 1)
			for _, key := range keys[2:] {
				if f.snapshot(key, false) != "" {
					t.Fatalf("expired/deleted row remains: %s", key)
				}
			}
			for _, key := range keys {
				f.requireOracle(key, later)
			}
		})
	}
}

func TestRollupIncrementalCoverageRecovery(t *testing.T) {
	for _, scenario := range []string{"rollups_lost", "scheduling_lost", "postmaster_changed", "source_truncated", "backward_clock"} {
		t.Run(scenario, func(t *testing.T) {
			f := newRollupFixture(t, true)
			key := f.item("recovery")
			f.signal(key, "recovery", f.at.Add(-time.Hour), f.at.Add(24*time.Hour))
			firstAt := f.at.Add(time.Second)
			if scenario == "scheduling_lost" {
				firstAt = f.at
			}
			f.refresh(firstAt)
			if scenario == "scheduling_lost" {
				f.requireCount(key, "signals_1h", 1)
			} else {
				f.requireCount(key, "signals_1h", 0)
			}
			at := f.at.Add(2 * time.Second)
			switch scenario {
			case "rollups_lost":
				f.exec(`TRUNCATE wire_signal_rollups`)
			case "scheduling_lost":
				f.exec(`TRUNCATE wire_signal_rollup_dirty,wire_signal_rollup_schedule`)
			case "postmaster_changed":
				f.exec(`UPDATE wire_signal_rollups SET signals_7d=999 WHERE canonical_key=$1`, key)
				f.exec(`UPDATE wire_signal_rollup_control SET postmaster_started_at='-infinity' WHERE singleton`)
			case "source_truncated":
				f.exec(`TRUNCATE wire_signal_events`)
			case "backward_clock":
				at = f.at
			}
			f.refresh(at)
			if scenario == "source_truncated" {
				if f.snapshot(key, false) != "" {
					t.Fatal("source truncate left stale rollup")
				}
			} else {
				f.requireCount(key, "signals_7d", 1)
			}
			if scenario == "backward_clock" {
				f.requireCount(key, "signals_1h", 1)
			}
			f.requireOracle(key, at)
		})
	}
}

func TestRollupNonSerializationAcknowledgmentFailureIsAtomic(t *testing.T) {
	f := newRollupFixture(t, true)
	key := f.item("failure")
	f.signal(key, "first", f.at, f.at.Add(24*time.Hour))
	f.refresh(f.at)
	before := f.snapshot(key, true)
	f.signal(key, "second", f.at, f.at.Add(24*time.Hour))
	function := "rollup_ack_" + strings.ReplaceAll(f.prefix[len("rollup-go-"):], "-", "")
	// Prefix-specific function names avoid interference with any other fixture.
	f.exec(`CREATE FUNCTION ` + function + `() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'injected acknowledgment failure' USING ERRCODE='P0001'; END$$`)
	t.Cleanup(func() {
		_, err := f.db.Exec(`DROP FUNCTION IF EXISTS ` + function + `() CASCADE`)
		if err != nil {
			t.Error(err)
		}
	})
	f.exec(`CREATE TRIGGER ` + function + ` BEFORE DELETE ON wire_signal_rollup_dirty FOR EACH ROW EXECUTE FUNCTION ` + function + `() `)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := f.store.Refresh(ctx, f.at)
	if !postgresState(err, "P0001") {
		t.Fatalf("wanted nonserialization error, got %v", err)
	}
	if f.snapshot(key, true) != before {
		t.Fatal("failed acknowledgment changed published snapshot")
	}
	f.exec(`DROP FUNCTION ` + function + `() CASCADE`)
	f.refresh(f.at)
	f.requireCount(key, "signals_7d", 2)
	f.requireOracle(key, f.at)
}

func TestRollupIncrementalPartitionDetachAndReattach(t *testing.T) {
	f := newRollupFixture(t, true)
	key := f.item("topology")
	future := time.Date(2081, time.January, 1, 0, 0, 0, 0, time.UTC)
	f.signal(key, "future", future, future.Add(24*time.Hour))
	f.refresh(f.at)
	f.requireCount(key, "signals_7d", 1)
	f.exec(`ALTER TABLE wire_signal_events DETACH PARTITION wire_signal_events_20810101`)
	t.Cleanup(func() {
		_, err := f.db.Exec(`DROP TABLE IF EXISTS wire_signal_events_20810101`)
		if err != nil {
			t.Error(err)
		}
	})
	f.refresh(f.at)
	if f.snapshot(key, false) != "" {
		t.Fatal("detached source partition left stale rollup")
	}
	f.exec(`ALTER TABLE wire_signal_events ATTACH PARTITION wire_signal_events_20810101 FOR VALUES FROM ('2081-01-01 00:00:00+00') TO ('2081-01-02 00:00:00+00')`)
	f.refresh(f.at)
	f.requireCount(key, "signals_7d", 1)
	f.requireOracle(key, f.at)
}
