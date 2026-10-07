package podcastcore

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

func fixtureStore(t *testing.T) (*Store, string) {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_PODCAST_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires isolated canonical PostgreSQL")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Ping(); err != nil {
		t.Fatal(err)
	}
	viewer := fmt.Sprintf("did:plc:go-podcast-%d", time.Now().UnixNano())
	t.Cleanup(func() {
		for _, table := range []string{"podcast_jobs", "podcast_clips", "podcast_subscriptions", "podcast_viewer_state", "podcast_private_shows"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec(`DELETE FROM podcast_aliases WHERE canonical_id LIKE $1`, viewer+"%")
		db.Exec(`DELETE FROM podcast_episodes WHERE show_id LIKE $1`, viewer+"%")
		db.Exec(`DELETE FROM podcast_shows WHERE id LIKE $1`, viewer+"%")
		db.Close()
	})
	return NewStore(db, base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))), viewer
}
func TestPublicCatalogIdentityPagingAndMetadataCAS(t *testing.T) {
	s, viewer := fixtureStore(t)
	ctx := context.Background()
	show := Show{ID: viewer + "-show", Title: "Show", SourceKind: "rss", FeedURL: pointer("https://example.invalid/" + viewer)}
	episodes := []Episode{}
	for i := 0; i < 3; i++ {
		episodes = append(episodes, Episode{ID: viewer + fmt.Sprintf("-episode-%d", i), ShowID: show.ID, Title: "Episode", PublishedAt: time.Date(2026, 10, 5, 0, 0, i, 0, time.UTC).Format(time.RFC3339), AudioURL: "https://example.invalid/audio.mp3", Guid: pointer(fmt.Sprint(i)), Chapters: []Chapter{{Title: "Intro", ArtworkURL: pointer("https://example.invalid/chapter.png")}}, ChapterSourceURL: pointer("https://example.invalid/chapters.json")})
	}
	if err := s.Upsert(ctx, show, episodes); err != nil {
		t.Fatal(err)
	}
	changed := episodes[0]
	changed.ID = viewer + "-new-id"
	changed.Chapters = nil
	changed.Title = "Updated title"
	if err := s.Upsert(ctx, show, []Episode{changed}); err != nil {
		t.Fatal(err)
	}
	canonical, err := s.Episode(ctx, changed.ID)
	if err != nil || canonical == nil || canonical.ID != episodes[0].ID || len(canonical.Chapters) != 1 {
		t.Fatalf("alias/chapter retention %v %v", canonical, err)
	}
	page, err := s.Episodes(ctx, show.ID, nil, 2)
	if err != nil || len(page) != 2 {
		t.Fatalf("page %v %v", page, err)
	}
	next, err := s.Episodes(ctx, show.ID, &page[1].ID, 2)
	if err != nil || len(next) != 1 {
		t.Fatalf("continuation %v %v", next, err)
	}
	stale := *canonical
	stale.AudioURL = "https://example.invalid/old.mp3"
	stale.Chapters = []Chapter{{Title: "Stale"}}
	if err := s.UpdateMetadata(ctx, stale, nil); err != nil {
		t.Fatal(err)
	}
	current, _ := s.Episode(ctx, canonical.ID)
	if current.Chapters[0].Title != "Intro" {
		t.Fatal("stale metadata overwrote source")
	}
	canonical.Chapters = []Chapter{{Title: "Current"}}
	if err := s.UpdateMetadata(ctx, *canonical, nil); err != nil {
		t.Fatal(err)
	}
	current, _ = s.Episode(ctx, canonical.ID)
	if current.Title != "Updated title" || current.Chapters[0].Title != "Current" {
		t.Fatal("metadata did not merge latest catalog")
	}
	if err := s.Subscriptions(ctx, viewer, []Subscription{{show.ID, "at://subscription"}}); err != nil {
		t.Fatal(err)
	}
	feed, err := s.SubscribedEpisodes(ctx, viewer, nil, 100)
	if err != nil || len(feed) != 3 {
		t.Fatalf("subscribed %v %v", feed, err)
	}
}
func TestPrivateOwnershipEncryptionRevisionAndDeletion(t *testing.T) {
	s, viewer := fixtureStore(t)
	ctx := context.Background()
	secret := "https://example.invalid/rss?token=private-secret"
	show, episodes := ScopePrivate(viewer, secret, Show{ID: "show", Title: "Private", SourceKind: "rss"}, []Episode{{ID: "episode", Title: "Private episode", PublishedAt: "2026-10-05T00:00:00Z", AudioURL: secret, Guid: pointer("guid"), Chapters: []Chapter{{Title: "Intro"}}, ChapterSourceURL: &secret}})
	if err := s.SavePrivateCatalog(ctx, viewer, secret, show, episodes, false); err != nil {
		t.Fatal(err)
	}
	var stored string
	if err := s.DB.QueryRow(`SELECT show_data||feed_data FROM podcast_private_shows WHERE viewer_did=$1 AND id=$2`, viewer, show.ID).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(stored, "private-secret") {
		t.Fatal("plaintext persisted")
	}
	got, err := s.PrivateEpisode(ctx, viewer, episodes[0].ID)
	if err != nil || got == nil || got.AudioURL != secret {
		t.Fatalf("private read %v %v", got, err)
	}
	if other, err := s.PrivateEpisode(ctx, viewer+"-other", episodes[0].ID); err != nil || other != nil {
		t.Fatal("cross viewer read", other, err)
	}
	wrong := NewStore(s.DB, base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{8}, 32)))
	if _, err := wrong.PrivateEpisode(ctx, viewer, episodes[0].ID); !errors.Is(err, ErrPrivateStorageUnavailable) {
		t.Fatal("wrong key accepted", err)
	}
	state := DefaultListenerState()
	state.Queue = []string{episodes[0].ID}
	state.Subscriptions = []string{show.ID}
	state.Progress[episodes[0].ID] = Progress{PositionSeconds: 5, UpdatedAt: "2026-10-05T00:00:00Z"}
	snap, err := s.SaveState(ctx, viewer, 0, state)
	if err != nil || snap.Revision != 1 {
		t.Fatalf("save %v %v", snap, err)
	}
	if _, err := s.SaveState(ctx, viewer, 0, state); !errors.Is(err, ErrRevisionConflict) {
		t.Fatal("stale revision accepted", err)
	}
	if _, err := s.SaveState(ctx, viewer+"-other", 0, state); !errors.Is(err, ErrInvalidState) {
		t.Fatal("cross viewer private queue", err)
	}
	queue, err := s.QueuedEpisodes(ctx, viewer)
	if err != nil || len(queue) != 1 {
		t.Fatal(queue, err)
	}
	removed, err := s.RemovePrivateSubscription(ctx, viewer, show.ID)
	if err != nil || !removed {
		t.Fatal("remove", removed, err)
	}
	snap, err = s.State(ctx, viewer)
	if err != nil || snap.Revision != 2 || len(snap.State.Queue) != 0 || len(snap.State.Progress) != 0 || len(snap.State.Subscriptions) != 0 {
		t.Fatal("state cleanup", snap, err)
	}
	if err := s.SavePrivateCatalog(ctx, viewer, secret, show, episodes, true); !errors.Is(err, ErrNotFound) {
		t.Fatal("refresh recreated deletion", err)
	}
}
func TestConcurrentStateCASAndAtomicClipJobs(t *testing.T) {
	s, viewer := fixtureStore(t)
	ctx := context.Background()
	state := DefaultListenerState()
	var wg sync.WaitGroup
	var mu sync.Mutex
	success, conflicts := 0, 0
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := s.SaveState(ctx, viewer, 0, state)
			mu.Lock()
			defer mu.Unlock()
			if err == nil {
				success++
			} else if errors.Is(err, ErrRevisionConflict) {
				conflicts++
			} else {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if success != 1 || conflicts != 7 {
		t.Fatal(success, conflicts)
	}
	show := Show{ID: viewer + "-show", Title: "Show", SourceKind: "rss"}
	episode := Episode{ID: viewer + "-episode", ShowID: show.ID, Title: "Episode", PublishedAt: "2026-10-05T00:00:00Z", AudioURL: "https://example.invalid/a.mp3"}
	if err := s.Upsert(ctx, show, []Episode{episode}); err != nil {
		t.Fatal(err)
	}
	clipID, _ := newUUID()
	clip := Clip{ID: clipID, EpisodeID: episode.ID, Title: "Clip", Status: "queued", EndSeconds: 30, CreatedAt: "2026-10-05T00:00:00Z"}
	if _, err := s.PrepareClip(ctx, viewer, clip, `{bad`); err == nil {
		t.Fatal("bad job payload accepted")
	}
	if c, err := s.Clip(ctx, clip.ID, &viewer, false); err != nil || c != nil {
		t.Fatal("draft escaped failed atomic job", c, err)
	}
	payload, _ := jsonValue(map[string]any{"clipId": clip.ID})
	jobID, err := s.PrepareClip(ctx, viewer, clip, payload)
	if err != nil {
		t.Fatal(err)
	}
	if job, err := s.Job(ctx, JobQuery{Viewer: viewer + "-other", JobID: &jobID}); err != nil || job != nil {
		t.Fatal("private job leaked")
	}
	if _, err := s.DB.Exec(`UPDATE podcast_jobs SET status='failed',error='failed' WHERE id=$1::uuid`, jobID); err != nil {
		t.Fatal(err)
	}
	if retried, err := s.Retry(ctx, viewer, jobID); err != nil || !retried {
		t.Fatal("retry", retried, err)
	}
	job, _ := s.Job(ctx, JobQuery{Viewer: viewer, JobID: &jobID})
	var row map[string]any
	if err := json.Unmarshal([]byte(*job), &row); err != nil || row["status"] != "queued" {
		t.Fatal("retry state", row, err)
	}
	if err := s.RemoveClip(ctx, viewer, clip, payload); err != nil {
		t.Fatal(err)
	}
	if c, _ := s.Clip(ctx, clip.ID, &viewer, false); c != nil {
		t.Fatal("clip retained")
	}
	cleanup, err := s.Job(ctx, JobQuery{Viewer: viewer, Kind: pointer("cleanup"), ClipID: &clip.ID})
	if err != nil || cleanup == nil {
		t.Fatal("cleanup not enqueued")
	}
}

func TestPrivateMetadataRequiresOwnerAndUnchangedSource(t *testing.T) {
	s, viewer := fixtureStore(t)
	ctx := context.Background()
	secret := "https://example.invalid/feed?token=private"
	show, episodes := ScopePrivate(viewer, secret, Show{Title: "Private", SourceKind: "rss"}, []Episode{{ID: "one", Title: "Original", PublishedAt: "2026-10-05T00:00:00Z", AudioURL: secret, ChapterSourceURL: &secret, Chapters: []Chapter{{Title: "Original chapter"}}}})
	if err := s.SavePrivateCatalog(ctx, viewer, secret, show, episodes, false); err != nil {
		t.Fatal(err)
	}
	candidate := episodes[0]
	candidate.Chapters = []Chapter{{Title: "New chapter"}}
	candidate.ShowArtworkURL = pointer("https://example.invalid/art.png")
	other := viewer + "-other"
	if err := s.UpdateMetadata(ctx, candidate, &other); err != nil {
		t.Fatal(err)
	}
	stale := candidate
	stale.ChapterSourceURL = pointer("https://example.invalid/stale.json")
	if err := s.UpdateMetadata(ctx, stale, &viewer); err != nil {
		t.Fatal(err)
	}
	got, err := s.PrivateEpisode(ctx, viewer, candidate.ID)
	if err != nil || got == nil || got.Chapters[0].Title != "Original chapter" {
		t.Fatal("wrong owner or stale source modified metadata", got, err)
	}
	// Enrichment may contain a stale title, but only chapter and show-art fields merge.
	candidate.Title = "Stale title"
	if err := s.UpdateMetadata(ctx, candidate, &viewer); err != nil {
		t.Fatal(err)
	}
	got, err = s.PrivateEpisode(ctx, viewer, candidate.ID)
	if err != nil || got.Title != "Original" || got.AudioURL != secret || got.Chapters[0].Title != "New chapter" || got.ShowArtworkURL == nil {
		t.Fatal("private merge changed catalog source", got, err)
	}
	var ciphertext string
	if err := s.DB.QueryRowContext(ctx, `SELECT episode_data FROM podcast_private_episodes WHERE viewer_did=$1 AND id=$2`, viewer, candidate.ID).Scan(&ciphertext); err != nil || strings.Contains(ciphertext, "private") || strings.Contains(ciphertext, "New chapter") {
		t.Fatal("metadata plaintext escaped encrypted storage", err)
	}
}
