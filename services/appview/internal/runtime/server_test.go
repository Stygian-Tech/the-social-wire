package runtime

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/appviewcore"
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestActualListenerHeartbeatAndJoinedShutdown(t *testing.T) {
	h := hostFixture(t, false, map[string]string{"OPERATIONS_TELEMETRY_ENABLED": "true", "RAILWAY_REPLICA_ID": "host-runtime-fixture"})
	t.Cleanup(func() {
		db := readinessDB(t)
		db.Exec(`DELETE FROM operations_service_state WHERE service='appview' AND instance_id='host-runtime-fixture'`)
		db.Exec(`DELETE FROM operations_metric_samples WHERE dimensions_json->>'instance_id'='host-runtime-fixture'`)
	})
	reserved, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	address := reserved.Addr().String()
	reserved.Close()
	h.Config.Address = address
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- h.Run(ctx) }()
	client := &http.Client{Timeout: time.Second}
	deadline := time.Now().Add(3 * time.Second)
	var response *http.Response
	for {
		response, e = client.Get("http://" + address + "/readyz")
		if e == nil {
			response.Body.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal(e)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if response.StatusCode != 200 {
		t.Fatal(response.StatusCode)
	}
	for {
		var count int
		e = h.DB.QueryRow(`SELECT COUNT(*) FROM operations_service_state WHERE service='appview' AND environment='prod' AND instance_id='host-runtime-fixture' AND readiness='healthy' AND freshness='unknown' AND completeness='unknown'`).Scan(&count)
		if e == nil && count == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("heartbeat missing", count, e)
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("listener or background jobs did not join")
	}
	if e = h.DB.Ping(); e == nil {
		t.Fatal("database pool remained open after shutdown")
	}
	if _, e = client.Get("http://" + address + "/livez"); e == nil {
		t.Fatal("listener remained live after shutdown")
	}
}
func TestHostCachedBootstrapStreamsSparseCountsAndReadOverlay(t *testing.T) {
	h := hostFixture(t, false, nil)
	at := time.Now().UTC().Truncate(time.Second)
	viewer := fmt.Sprintf("did:plc:hostbootstrap%d", at.UnixNano())
	publication := "host-bootstrap-fixture"
	uri := "at://" + viewer + "/site.standard.document/entry"
	t.Cleanup(func() {
		for _, table := range []string{"sidebar_projection_cache", "first_page_cache", "appview_unread_counters", "unread_counts_cache", "read_marks"} {
			h.DB.Exec("DELETE FROM "+table+" WHERE viewer_did=$1", viewer)
		}
	})
	row := publicationcore.SidebarRow{PublicationID: publication, AuthorDID: viewer, DiscoveredAt: at, AppViewScope: publicationcore.AppViewScope{AuthorDID: viewer, PublicationScopeATURIs: []string{}, PublicationSiteURLs: []string{}}}
	zero := row
	zero.PublicationID = "host-bootstrap-zero"
	snapshot := publicationcore.BootstrapSnapshot{Version: 1, Priority: publicationcore.Sidebar{ViewerDID: viewer, MyPublications: []publicationcore.SidebarRow{row, zero}, AllPublicationRows: []publicationcore.SidebarRow{row, zero}, SubscribedUnfoldered: []publicationcore.SidebarRow{}, FollowingTabPublications: []publicationcore.SidebarRow{}, RefreshedAt: at}, FolderPayload: &publicationcore.FolderPayload{FolderSections: []publicationcore.FolderSection{}, AllPublicationRows: []publicationcore.SidebarRow{row}}}
	if e := h.Publications.Cache.Store(context.Background(), viewer, snapshot, at); e != nil {
		t.Fatal(e)
	}
	if _, e := h.DB.Exec(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)VALUES($1,$2,1,7,'exact',FALSE,$3)`, viewer, publication, at); e != nil {
		t.Fatal(e)
	}
	if _, e := h.DB.Exec(`INSERT INTO appview_unread_counters(viewer_did,publication_id,unread_count,generation,accuracy,dirty,counted_at)VALUES($1,'host-bootstrap-zero',0,7,'exact',FALSE,$2)`, viewer, at); e != nil {
		t.Fatal(e)
	}
	raw, _ := publicationcore.EncodeFirstPage(appviewcore.EntryPage{Entries: []appviewcore.Entry{{EntryID: uri, Title: "cached first entry", PublishedAt: at, FeedPositionAt: at}}})
	if e := h.Publications.Cache.Projection.StoreFirstPage(context.Background(), viewer, publication, string(raw), at); e != nil {
		t.Fatal(e)
	}
	if _, e := h.DB.Exec(`INSERT INTO read_marks(viewer_did,subject_uri,created_at)VALUES($1,$2,$3)`, viewer, uri, at); e != nil {
		t.Fatal(e)
	}
	response := serveHost(h, "GET", "/v1/appview/bootstrap-stream", viewer)
	if response.Code != 200 || !strings.Contains(response.Header().Get("Content-Type"), "application/x-ndjson") {
		t.Fatal(response.Code, response.Body.String())
	}
	scanner := bufio.NewScanner(strings.NewReader(response.Body.String()))
	kinds := []string{}
	events := map[string]map[string]any{}
	for scanner.Scan() {
		var event map[string]any
		if e := json.Unmarshal(scanner.Bytes(), &event); e != nil {
			t.Fatal(e)
		}
		kind, _ := event["kind"].(string)
		kinds = append(kinds, kind)
		events[kind] = event
	}
	if e := scanner.Err(); e != nil {
		t.Fatal(e)
	}
	if fmt.Sprint(kinds) != "[sidebarPriority sidebarFolders unreadCounts selectedPublication entriesPage done]" {
		t.Fatal(kinds)
	}
	counts := events["unreadCounts"]["unreadCounts"].(map[string]any)
	if len(counts["counts"].(map[string]any)) != 1 || fmt.Sprint(counts["replacePublicationIds"]) != "[host-bootstrap-fixture host-bootstrap-zero]" {
		t.Fatal(counts)
	}
	data, _ := json.Marshal(events["entriesPage"])
	if strings.Contains(string(data), `"isRead"`) || strings.Contains(string(data), `"feedPositionAt"`) || !strings.Contains(string(data), `"cached first entry"`) {
		t.Fatal("bootstrap DTO changed source field contract", string(data))
	}
	hit, e := h.Publications.Cache.CachedPage(context.Background(), viewer, publication, 50, at)
	if e != nil || hit == nil || !hit.Page.Entries[0].IsRead {
		t.Fatal("internal cache missed read overlay", hit, e)
	}
	done := events["done"]["done"].(map[string]any)
	if done["source"] != "projection_cache" {
		t.Fatal(done)
	}
}
