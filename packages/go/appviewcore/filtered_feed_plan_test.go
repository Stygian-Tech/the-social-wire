package appviewcore

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestFilteredFeedIdentitySkipsBodyLookup(t *testing.T) {
	db := fixtureDatabase(t)
	now := time.Now().UTC()
	uri := fmt.Sprintf("at://did:plc:identity-plan/site.standard.document/%d", now.UnixNano())
	render := `{"title":"Body","articleUrl":"https://example.test/article","contentHTML":"` + strings.Repeat("body ", 20000) + `"}`
	if _, err := db.Exec(`INSERT INTO content_items(uri,cid,author_did,collection,created_at,indexed_at,publication_site,render_json,expires_at) VALUES($1,'fixture','did:plc:identity-plan','site.standard.document',$2,$2,'site',$3,$4)`, uri, now, render, now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Exec(`DELETE FROM content_items WHERE uri=$1`, uri) })
	site := "site"
	raw, err := json.Marshal([]feedMetadata{{ID: 0, URI: uri, At: now, Publication: "pub", Author: "did:plc:identity-plan", Site: &site}})
	if err != nil {
		t.Fatal(err)
	}
	var plan []byte
	if err := db.QueryRowContext(context.Background(), "EXPLAIN(ANALYZE,FORMAT JSON) "+feedHydrateQuery, string(raw), "did:plc:identity-plan-viewer").Scan(&plan); err != nil {
		t.Fatal(err)
	}
	var decoded []struct{ Plan map[string]any }
	if err := json.Unmarshal(plan, &decoded); err != nil {
		t.Fatal(err)
	}
	found := false
	var visit func(map[string]any)
	visit = func(node map[string]any) {
		if node["Relation Name"] == "content_items" {
			found = true
			if node["Actual Loops"].(float64) != 0 {
				t.Fatalf("projected identity fetched body: %s", plan)
			}
		}
		if children, ok := node["Plans"].([]any); ok {
			for _, child := range children {
				visit(child.(map[string]any))
			}
		}
	}
	visit(decoded[0].Plan)
	if !found {
		t.Fatalf("missing guarded fallback in plan: %s", plan)
	}
	// An interrupted backfill keeps the exact legacy identity and read state.
	if _, err := db.Exec(`DELETE FROM content_item_article_identities WHERE uri=$1`, uri); err != nil {
		t.Fatal(err)
	}
	var id int64
	var key string
	var read bool
	if err := db.QueryRowContext(context.Background(), feedHydrateQuery, string(raw), "did:plc:identity-plan-viewer").Scan(&id, &key, &read); err != nil {
		t.Fatal(err)
	}
	if id != 0 || key != "https://example.test/article" || read {
		t.Fatalf("fallback identity/state: %d %q %t", id, key, read)
	}
}
