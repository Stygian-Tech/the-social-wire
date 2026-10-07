package wireworkercore

import (
	"context"
	"testing"
	"time"
)

func TestGraphCommunityQualificationAndCadence(t *testing.T) {
	db := generationDatabase(t)
	ctx := context.Background()
	id, _ := newGenerationID()
	at := time.Now().UTC().Truncate(time.Microsecond)
	actors := []string{id + "-a", id + "-b", id + "-c", id + "-isolated"}
	t.Cleanup(func() {
		for _, actor := range actors {
			_, _ = db.Exec(`DELETE FROM wire_follow_edges WHERE follower_key_hash=$1 OR followee_key_hash=$1`, actor)
			_, _ = db.Exec(`DELETE FROM wire_actor_communities WHERE actor_key_hash=$1`, actor)
			_, _ = db.Exec(`DELETE FROM wire_active_actors WHERE actor_key_hash=$1`, actor)
		}
	})
	for _, actor := range actors {
		if _, err := db.Exec(`INSERT INTO wire_active_actors(actor_key_hash,first_active_at,last_active_at,public_signal_count,expires_at)VALUES($1,$2,$2,1,$3)`, actor, at, at.Add(24*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 2; i++ {
		if _, err := db.Exec(`INSERT INTO wire_follow_edges(follower_key_hash,followee_key_hash,source_uri,observed_at,expires_at)VALUES($1,$2,$3,$4,$5)`, actors[i], actors[i+1], "at://"+id+"/follow/"+actors[i], at, at.Add(24*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	// Fixture isolates the cadence table; an earlier test may have produced no communities.
	if _, err := db.Exec(`DELETE FROM wire_actor_communities`); err != nil {
		t.Fatal(err)
	}
	store := GraphMaintenance{DB: db}
	next, err := store.RefreshCommunities(ctx, at)
	if err != nil {
		t.Fatal(err)
	}
	if !next.Equal(at.Add(6 * time.Hour)) {
		t.Fatal(next)
	}
	var count int
	var distinct int
	if err = db.QueryRow(`SELECT count(*),count(DISTINCT community_key_hash)FROM wire_actor_communities WHERE actor_key_hash IN($1,$2,$3,$4)`, actors[0], actors[1], actors[2], actors[3]).Scan(&count, &distinct); err != nil {
		t.Fatal(err)
	}
	if count != 3 || distinct != 1 {
		t.Fatalf("qualification %d %d", count, distinct)
	}
	same, err := store.RefreshCommunities(ctx, at.Add(time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if !same.Equal(next) {
		t.Fatalf("cadence changed %s", same)
	}
}
