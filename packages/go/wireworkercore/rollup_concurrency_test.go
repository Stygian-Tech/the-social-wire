package wireworkercore

import (
	"context"
	"testing"
	"time"
)

func TestRollupConcurrentAcknowledgmentPublishesSnapshotAndCatchesUp(t *testing.T) {
	f := newRollupFixture(t, true)
	key := f.item("acknowledgment")
	expires := f.at.Add(24 * time.Hour)
	f.signal(key, "first", f.at, expires)
	f.refresh(f.at)
	f.signal(key, "second", f.at, expires)
	f.exec(`DELETE FROM wire_signal_rollup_dirty WHERE canonical_key=$1`, key)
	f.exec(`INSERT INTO wire_signal_rollup_dirty(canonical_key,shard)VALUES($1,0)`, key)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	blocker, err := f.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback()
	var pid int
	if err = blocker.QueryRowContext(ctx, `SELECT pg_backend_pid() FROM wire_signal_rollups WHERE canonical_key=$1 FOR UPDATE`, key).Scan(&pid); err != nil {
		t.Fatal(err)
	}
	completed := make(chan error, 1)
	go func() { completed <- f.store.Refresh(ctx, f.at) }()
	// Observe the real publication lock rather than relying on a timing delay.
	waiting := false
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		err = f.db.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE $1=ANY(pg_blocking_pids(pid)) AND query LIKE '%UPDATE wire_signal_rollups current%')`, pid).Scan(&waiting)
		if err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case err := <-completed:
			t.Fatalf("refresh exited before publication barrier: %v", err)
		case <-time.After(10 * time.Millisecond):
		}
	}
	if !waiting {
		t.Fatal("refresh did not reach publication barrier")
	}
	// Partition is already present; only insert source rows while topology is locked.
	f.insertSignal(key, "third", f.at, expires)
	f.exec(`INSERT INTO wire_signal_rollup_dirty(canonical_key,shard)VALUES($1,0) ON CONFLICT(canonical_key,shard)DO UPDATE SET revision=EXCLUDED.revision`, key)
	if err = blocker.Commit(); err != nil {
		t.Fatal(err)
	}
	select {
	case err = <-completed:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	f.requireCount(key, "signals_7d", 2)
	var retained int
	if err = f.db.QueryRow(`SELECT count(*) FROM wire_signal_rollup_dirty WHERE canonical_key=$1 AND shard=0`, key).Scan(&retained); err != nil {
		t.Fatal(err)
	}
	if retained != 1 {
		t.Fatal("concurrent revision was acknowledged")
	}
	f.refresh(f.at)
	f.requireCount(key, "signals_7d", 3)
	f.requireOracle(key, f.at)
	if err = f.db.QueryRow(`SELECT count(*) FROM wire_signal_rollup_dirty WHERE canonical_key=$1`, key).Scan(&retained); err != nil {
		t.Fatal(err)
	}
	if retained != 0 {
		t.Fatal("catch-up did not drain dirty hints")
	}
}

func TestRollupLockedDirtyHintsDoNotBlockPublication(t *testing.T) {
	f := newRollupFixture(t, true)
	key := f.item("locked-dirty")
	expires := f.at.Add(24 * time.Hour)
	f.signal(key, "first", f.at, expires)
	f.refresh(f.at)
	f.signal(key, "second", f.at, expires)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	writer, err := f.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer writer.Rollback()
	if _, err = writer.ExecContext(ctx, `SELECT revision FROM wire_signal_rollup_dirty WHERE canonical_key=$1 FOR UPDATE`, key); err != nil {
		t.Fatal(err)
	}
	// A regression to blocking acknowledgment fails the context while lock stays held.
	if err = f.store.Refresh(ctx, f.at); err != nil {
		t.Fatal(err)
	}
	f.requireCount(key, "signals_7d", 2)
	var pending int
	if err = writer.QueryRowContext(ctx, `SELECT count(*) FROM wire_signal_rollup_dirty WHERE canonical_key=$1`, key).Scan(&pending); err != nil {
		t.Fatal(err)
	}
	if pending == 0 {
		t.Fatal("locked hints were discarded")
	}
	if err = writer.Commit(); err != nil {
		t.Fatal(err)
	}
	f.refresh(f.at)
	if err = f.db.QueryRow(`SELECT count(*) FROM wire_signal_rollup_dirty WHERE canonical_key=$1`, key).Scan(&pending); err != nil {
		t.Fatal(err)
	}
	if pending != 0 {
		t.Fatal("unlocked hints did not drain")
	}
}
