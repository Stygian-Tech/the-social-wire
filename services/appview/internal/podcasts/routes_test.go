package podcasts

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/podcastcore"
)

type fakeRepository struct{ Records map[string]map[string]any }

func (f *fakeRepository) GetRecord(ctx context.Context, did, collection, key, cid string) (*gatewaycore.RepoRecord, error) {
	uri := "at://" + did + "/" + collection + "/" + key
	value := f.Records[uri]
	if value == nil {
		return nil, nil
	}
	raw := map[string]json.RawMessage{}
	for key, v := range value {
		raw[key], _ = json.Marshal(v)
	}
	return &gatewaycore.RepoRecord{URI: uri, Value: raw}, nil
}
func (f *fakeRepository) ListRecords(context.Context, string, string, string, int, bool) (gatewaycore.RepoPage, error) {
	return gatewaycore.RepoPage{Records: []gatewaycore.RepoRecord{}}, nil
}
func (f *fakeRepository) ResolvePDS(context.Context, string) (string, error) {
	return "https://pds.publisher.com", nil
}
func fixtureService(t *testing.T) (*Service, string, *fakeRepository) {
	t.Helper()
	dsn := os.Getenv("SOCIALWIRE_GO_PODCAST_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires isolated canonical Postgres")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Ping(); err != nil {
		t.Fatal(err)
	}
	viewer := fmt.Sprintf("did:plc:go-podcast-route-%d", time.Now().UnixNano())
	repo := &fakeRepository{Records: map[string]map[string]any{}}
	service := &Service{Store: podcastcore.NewStore(db, base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))), Repo: repo, Now: func() time.Time { return time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC) }}
	t.Cleanup(func() {
		service.Close()
		for _, table := range []string{"podcast_jobs", "podcast_clips", "podcast_subscriptions", "podcast_viewer_state", "podcast_private_shows"} {
			db.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
		db.Exec(`DELETE FROM podcast_aliases WHERE canonical_id LIKE $1`, viewer+"%")
		db.Exec(`DELETE FROM podcast_episodes WHERE show_id LIKE $1`, viewer+"%")
		db.Exec(`DELETE FROM podcast_shows WHERE id LIKE $1`, viewer+"%")
		db.Close()
	})
	return service, viewer, repo
}
func requestRoute(mux *http.ServeMux, method, path, body, viewer string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	if viewer != "" {
		request = request.WithContext(gatewaycore.ContextWithAuth(request.Context(), gatewaycore.AuthContext{DID: viewer}))
	}
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	return response
}
func TestPodcastRoutesRejectAnonymousBeforeStorage(t *testing.T) {
	mux := http.NewServeMux()
	Routes{}.Register(mux)
	for _, pattern := range []string{"POST /v1/podcasts/search", "POST /v1/podcasts/resolve", "GET /v1/podcasts/shows", "GET /v1/podcasts/episodes", "GET /v1/podcasts/state", "PUT /v1/podcasts/state", "GET /v1/podcasts/transcript", "POST /v1/podcasts/analysis", "GET /v1/podcasts/analysis", "GET /v1/podcasts/jobs", "POST /v1/podcasts/jobs", "POST /v1/podcasts/clips", "GET /v1/podcasts/clips", "POST /v1/podcasts/clips/publish", "DELETE /v1/podcasts/clips", "POST /v1/podcasts/private/resolve", "POST /v1/podcasts/private/refresh", "DELETE /v1/podcasts/private/subscriptions"} {
		parts := strings.SplitN(pattern, " ", 2)
		for _, viewer := range []string{"", gatewaycore.AnonymousDiscoveryDID} {
			if response := requestRoute(mux, parts[0], parts[1], "{}", viewer); response.Code != 401 {
				t.Fatal(pattern, response.Code)
			}
		}
	}
}
func TestEpisodeArtworkClipJobAndLivePublicRecord(t *testing.T) {
	service, viewer, repo := fixtureService(t)
	show := podcastcore.Show{ID: viewer + "-show", Title: "Primary Technology", SourceKind: "rss", ArtworkURL: pointer("https://publisher.com/show.png")}
	episode := podcastcore.Episode{ID: viewer + "-episode", ShowID: show.ID, Title: "Episode", PublishedAt: "2026-10-05T00:00:00Z", AudioURL: "https://publisher.com/audio.mp3", ArtworkURL: pointer("https://publisher.com/episode.png"), DurationSeconds: pointer(3600.0), Chapters: []podcastcore.Chapter{{Title: "Intro", ArtworkURL: pointer("https://publisher.com/chapter.png")}}}
	if err := service.Store.Upsert(context.Background(), show, []podcastcore.Episode{episode}); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	Routes{Service: service}.Register(mux)
	Routes{Service: service}.RegisterPublic(mux)
	response := requestRoute(mux, "GET", "/v1/podcasts/episodes?episodeId="+episode.ID, "", viewer)
	if response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	var page struct {
		Episodes []podcastcore.Episode `json:"episodes"`
		Cursor   *string               `json:"cursor"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &page); err != nil || len(page.Episodes) != 1 || page.Cursor != nil || *page.Episodes[0].ArtworkURL != *episode.ArtworkURL || *page.Episodes[0].ShowArtworkURL != *show.ArtworkURL || page.Episodes[0].Chapters[0].ArtworkURL == nil {
		t.Fatal("artwork response", page, err)
	}
	body, _ := json.Marshal(ClipRequest{EpisodeID: episode.ID, StartSeconds: 10, EndSeconds: 40, IncludeCaptions: pointer(false)})
	response = requestRoute(mux, "POST", "/v1/podcasts/clips", string(body), viewer)
	if response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	var created map[string]string
	json.Unmarshal(response.Body.Bytes(), &created)
	clipID := created["clipId"]
	jobID := created["jobId"]
	if clipID == "" || jobID == "" {
		t.Fatal(created)
	}
	var payload string
	if err := service.Store.DB.QueryRow(`SELECT payload_json::text FROM podcast_jobs WHERE id=$1::uuid`, jobID).Scan(&payload); err != nil {
		t.Fatal(err)
	}
	var job map[string]any
	json.Unmarshal([]byte(payload), &job)
	if job["startSeconds"] != 10.0 || job["endSeconds"] != 40.0 || job["clipId"] != clipID {
		t.Fatal("worker payload", job)
	}
	if _, err := service.Store.DB.Exec(`UPDATE podcast_clips SET clip_json=clip_json || '{"status":"complete","publicAudioUrl":"https://publisher.com/clip.m4a","publicVideoUrl":"https://publisher.com/clip.mp4"}'::jsonb WHERE id=$1::uuid`, clipID); err != nil {
		t.Fatal(err)
	}
	uri := "at://" + viewer + "/app.thesocialwire.podcast.clip/published"
	repo.Records[uri] = map[string]any{"$type": "app.thesocialwire.podcast.clip", "episodeId": episode.ID, "startMillis": 10000, "endMillis": 40000, "audioUrl": "https://publisher.com/clip.m4a", "videoUrl": "https://publisher.com/clip.mp4"}
	publish, _ := json.Marshal(map[string]string{"clipId": clipID, "uri": uri})
	response = requestRoute(mux, "POST", "/v1/podcasts/clips/publish", string(publish), viewer)
	if response.Code != 200 {
		t.Fatal(response.Code, response.Body.String())
	}
	if response := requestRoute(mux, "GET", "/v1/podcasts/public/clips?clipId="+clipID, "", ""); response.Code != 200 {
		t.Fatal("public clip", response.Code, response.Body.String())
	}
	delete(repo.Records, uri)
	if response := requestRoute(mux, "GET", "/v1/podcasts/public/clips?clipId="+clipID, "", ""); response.Code != 404 {
		t.Fatal("deleted PDS record remained public", response.Code)
	}
}
func TestPrivateClipAndMalformedStateDenied(t *testing.T) {
	service, viewer, _ := fixtureService(t)
	secret := "https://publisher.com/private?token=secret"
	show, episodes := podcastcore.ScopePrivate(viewer, secret, podcastcore.Show{Title: "Private", SourceKind: "rss"}, []podcastcore.Episode{{ID: "episode", Title: "Private", PublishedAt: "2026-10-05T00:00:00Z", AudioURL: secret}})
	if err := service.Store.SavePrivateCatalog(context.Background(), viewer, secret, show, episodes, false); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	Routes{Service: service}.Register(mux)
	body, _ := json.Marshal(ClipRequest{EpisodeID: episodes[0].ID, EndSeconds: 30, IncludeCaptions: pointer(false)})
	if response := requestRoute(mux, "POST", "/v1/podcasts/clips", string(body), viewer); response.Code != 403 {
		t.Fatal(response.Code, response.Body.String())
	}
	if response := requestRoute(mux, "POST", "/v1/podcasts/clips", string(body), viewer+"other"); response.Code != 404 {
		t.Fatal("owner info disclosed", response.Code)
	}
	for _, invalid := range []string{`{"expectedRevision":0,"state":{}}`, `{"query":"Primary Technology"} {}`, `{"episodeId":"x","startSeconds":null,"endSeconds":30}`} {
		path := "/v1/podcasts/state"
		method := "PUT"
		if strings.Contains(invalid, "query") {
			path = "/v1/podcasts/search"
			method = "POST"
		} else if strings.Contains(invalid, "episodeId") {
			path = "/v1/podcasts/clips"
			method = "POST"
		}
		if response := requestRoute(mux, method, path, invalid, viewer); response.Code != 400 {
			t.Fatal("malformed body accepted", response.Code, response.Body.String())
		}
	}
}
