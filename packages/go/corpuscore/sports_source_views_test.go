package corpuscore

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func applySportsSourceViews(t *testing.T, db *sql.DB) {
	t.Helper()
	raw, err := os.ReadFile("../../../database/migrations/20261012010000_sports_lean_source_views.sql")
	if err != nil {
		t.Fatal(err)
	}
	execFixture(t, db, string(raw))
}

func TestPostgresSportsSourceViewsParityAndCurrentGates(t *testing.T) {
	db := corpusDB(t)
	applySportsSourceViews(t, db)
	now := time.Now().UTC()
	id := "d7110000-1111-1111-1111-111111111111"
	keys := []string{"sports-source-view-a", "sports-source-view-b"}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM sports_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=ANY($1::text[])`, keys)
	})
	for _, key := range keys {
		execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code)VALUES($1,'https://example.test/'||$1,'example.test','Fixture','Fixture',$2,$2,$3,'en')`, key, now, now.Add(time.Hour))
	}
	payload, _ := json.Marshal([]map[string]any{{"item": map[string]string{"itemId": keys[0]}, "baseScore": 3}, {"item": map[string]string{"itemId": keys[1]}, "baseScore": 2}, {"item": map[string]string{"itemId": keys[0]}, "baseScore": 1}})
	execFixture(t, db, `INSERT INTO sports_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'en','fixture',$2,$3,$4::jsonb,FALSE)`, id, now, now.Add(time.Hour), payload)
	parity := func(expected []int) {
		t.Helper()
		var legacy, current []byte
		if err := db.QueryRow(`SELECT payload::text FROM wire_serving.sports_generations WHERE generation_id=$1::uuid`, id).Scan(&legacy); err != nil {
			t.Fatal(err)
		}
		if err := db.QueryRow(`SELECT COALESCE(jsonb_agg(candidate ORDER BY ordinal),'[]'::jsonb)::text FROM wire_serving.sports_source_candidates WHERE generation_id=$1::uuid`, id).Scan(&current); err != nil {
			t.Fatal(err)
		}
		var a, b any
		json.Unmarshal(legacy, &a)
		json.Unmarshal(current, &b)
		if !reflect.DeepEqual(a, b) {
			t.Fatal("legacy/new candidate parity", string(legacy), string(current))
		}
		rows, err := db.Query(`SELECT ordinal FROM wire_serving.sports_source_candidates WHERE generation_id=$1::uuid ORDER BY ordinal`, id)
		if err != nil {
			t.Fatal(err)
		}
		ordinals := []int{}
		for rows.Next() {
			var ordinal int
			if err = rows.Scan(&ordinal); err != nil {
				t.Fatal(err)
			}
			ordinals = append(ordinals, ordinal)
		}
		if err = rows.Err(); err != nil {
			t.Fatal(err)
		}
		rows.Close()
		if !reflect.DeepEqual(ordinals, expected) {
			t.Fatal("ordinal/duplicate mismatch", ordinals, expected)
		}
		var stamp string
		if err = db.QueryRow(`SELECT cache_revision FROM wire_serving.sports_source_heads WHERE generation_id=$1::uuid`, id).Scan(&stamp); err != nil || len(strings.Split(stamp, ":")) != 3 {
			t.Fatal(stamp, err)
		}
	}
	parity([]int{1, 2, 3})
	for _, change := range []string{`eligible=FALSE`, `expires_at=CURRENT_TIMESTAMP-INTERVAL '1 hour'`, `target_kind='social_post'`, `commercial_class='probable_ad'`, `language_code='fr'`} {
		execFixture(t, db, `UPDATE wire_items SET `+change+` WHERE canonical_key=$1`, keys[0])
		parity([]int{2})
		execFixture(t, db, `UPDATE wire_items SET eligible=TRUE,expires_at=$2,target_kind='external_article',commercial_class='normal',language_code='en' WHERE canonical_key=$1`, keys[0], now.Add(time.Hour))
	}
	for _, label := range []string{"block", "exclude", "adult", "graphic", "spam"} {
		execFixture(t, db, `INSERT INTO wire_labels(canonical_key,label_key,label_value,source,applied_at,expires_at)VALUES($1,$2,$2,'fixture',$3,$4)`, keys[0], label, now, now.Add(time.Hour))
		parity([]int{2})
		execFixture(t, db, `DELETE FROM wire_labels WHERE canonical_key=$1`, keys[0])
	}
	execFixture(t, db, `UPDATE wire_items SET language_code='fr' WHERE canonical_key=$1`, keys[0])
	execFixture(t, db, `UPDATE sports_generations SET language='und' WHERE generation_id=$1::uuid`, id)
	parity([]int{1, 2, 3})
	execFixture(t, db, `DELETE FROM wire_items WHERE canonical_key=ANY($1::text[])`, keys)
	parity([]int{}) // Head survives zero eligible candidates.
	execFixture(t, db, `UPDATE sports_generations SET expires_at=$2 WHERE generation_id=$1::uuid`, id, now.Add(-time.Hour))
	for _, view := range []string{"sports_generations", "sports_source_heads", "sports_source_candidates"} {
		var count int
		if err := db.QueryRow(`SELECT count(*) FROM wire_serving.`+view+` WHERE generation_id=$1::uuid`, id).Scan(&count); err != nil || count != 0 {
			t.Fatal("expired generation", view, count, err)
		}
	}
}

func TestPostgresSportsSourceViewsReaderGrantsAndRawDenial(t *testing.T) {
	db := corpusDB(t)
	reader := fmt.Sprintf("sports_view_reader_%d", time.Now().UnixNano())
	outsider := reader + "_outside"
	execFixture(t, db, `CREATE ROLE `+reader+` NOLOGIN`)
	execFixture(t, db, `CREATE ROLE `+outsider+` NOLOGIN`)
	t.Cleanup(func() {
		db.Exec(`RESET ROLE`)
		for _, role := range []string{reader, outsider} {
			db.Exec(`DROP OWNED BY ` + role)
			db.Exec(`DROP ROLE ` + role)
		}
	})
	execFixture(t, db, `GRANT USAGE ON SCHEMA wire_serving TO `+reader+`,`+outsider)
	execFixture(t, db, `GRANT SELECT ON wire_serving.items TO `+reader)
	applySportsSourceViews(t, db)
	for _, view := range []string{"sports_source_heads", "sports_source_candidates", "finance_source_heads", "finance_source_candidates", "finance_source_instruments"} {
		var allowed, write, outside bool
		if err := db.QueryRow(`SELECT has_table_privilege($1,$3,'SELECT'),has_table_privilege($1,$3,'INSERT,UPDATE,DELETE'),has_table_privilege($2,$3,'SELECT')`, reader, outsider, "wire_serving."+view).Scan(&allowed, &write, &outside); err != nil || !allowed || write || outside {
			t.Fatal(view, allowed, write, outside, err)
		}
		var barrier bool
		if err := db.QueryRow(`SELECT 'security_barrier=true'=ANY(reloptions) FROM pg_class WHERE oid=$1::regclass`, "wire_serving."+view).Scan(&barrier); err != nil || !barrier {
			t.Fatal(view, barrier, err)
		}
	}
	for _, table := range []string{"sports_generations", "wire_items", "wire_labels", "sports_article_analysis", "sports_selections", "finance_generations", "finance_instruments", "finance_selections"} {
		var allowed bool
		if err := db.QueryRow(`SELECT has_table_privilege($1,$2,'SELECT')`, reader, table).Scan(&allowed); err != nil || allowed {
			t.Fatal("raw privilege", table, allowed, err)
		}
	}
	execFixture(t, db, `SET ROLE `+reader)
	for _, view := range []string{"sports_source_heads", "sports_source_candidates", "finance_source_heads", "finance_source_candidates", "finance_source_instruments"} {
		var count int
		if err := db.QueryRow(`SELECT count(*) FROM wire_serving.` + view).Scan(&count); err != nil {
			t.Fatal("granted view unreadable", view, err)
		}
	}
	for _, table := range []string{"sports_generations", "wire_items"} {
		if _, err := db.Exec(`SELECT * FROM ` + table + ` LIMIT 1`); err == nil {
			t.Fatal("raw table readable", table)
		}
	}
	execFixture(t, db, `RESET ROLE`)
}

func TestPostgresSportsSourceWarmPlanSkipsCandidateJSONAggregation(t *testing.T) {
	db := corpusDB(t)
	applySportsSourceViews(t, db)
	now := time.Now().UTC()
	id := "d7110000-2222-2222-2222-222222222222"
	key := "sports-source-view-plan"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM sports_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM sports_catalog_snapshots WHERE snapshot_id=$1::uuid`, id)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=$1`, key)
	})
	execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code)VALUES($1,'https://example.test/'||$1,'example.test','Fixture','Fixture',$2,$2,$3,'xx')`, key, now, now.Add(time.Hour))
	execFixture(t, db, `INSERT INTO sports_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)SELECT $1::uuid,$1::uuid,'xx','plan-fixture',$2,$3,jsonb_agg(jsonb_build_object('item',jsonb_build_object('itemId',$4::text,'canonicalUrl','https://example.test/plan','title','Fixture','summary',repeat('x',4096),'source',jsonb_build_object('domain','example.test')),'analysis',jsonb_build_object('resolverVersion','fixture'),'baseScore',1,'majorGlobal',false)),TRUE FROM generate_series(1,5000)`, id, now, now.Add(time.Hour), key)
	// An existing canonical catalog is enough for this query-plan fixture. If the
	// test database has none, add one isolated empty catalog for the CROSS JOIN.
	var catalogs int
	if err := db.QueryRow(`SELECT count(*) FROM sports_catalog_snapshots WHERE is_active=TRUE`).Scan(&catalogs); err != nil {
		t.Fatal(err)
	}
	if catalogs == 0 {
		execFixture(t, db, `INSERT INTO sports_catalog_snapshots(snapshot_id,version,generated_at,payload,is_active)VALUES($1::uuid,'plan-fixture',$2,'{"entities":[]}',TRUE)`, id, now)
	}
	var revision string
	if err := db.QueryRow(sportsSourceProjection+`SELECT revision FROM current_source`, "xx", now).Scan(&revision); err != nil {
		t.Fatal(err)
	}
	query := sportsSourceProjection + `SELECT generation_id,generated_at,expires_at,version,lean_catalog_generated,revision,CASE WHEN generation_id::text=$3 AND revision=$4 THEN NULL ELSE ` + sportsSourceCandidatePayload + ` END FROM current_source`
	var raw []byte
	if err := db.QueryRow(`EXPLAIN(ANALYZE,VERBOSE,FORMAT JSON) `+query, "xx", now, id, revision).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var plans []map[string]any
	if err := json.Unmarshal(raw, &plans); err != nil {
		t.Fatal(err)
	}
	fullAggregates, ordinalAggregates := 0, 0
	var walk func(map[string]any)
	walk = func(node map[string]any) {
		output, _ := json.Marshal(node["Output"])
		if node["Node Type"] == "Aggregate" && strings.Contains(string(output), "jsonb_agg") {
			if strings.Contains(string(output), "'itemId'") {
				fullAggregates++
				if node["Actual Loops"].(float64) != 0 {
					t.Fatal("warm full candidate aggregate executed", string(output))
				}
			}
			if strings.Contains(string(output), "candidate.ordinal") {
				ordinalAggregates++
			}
		}
		children, _ := node["Plans"].([]any)
		for _, child := range children {
			walk(child.(map[string]any))
		}
	}
	walk(plans[0]["Plan"].(map[string]any))
	if fullAggregates == 0 || ordinalAggregates == 0 {
		t.Fatal("representative plan did not contain both guarded candidate and current ordinal aggregates", fullAggregates, ordinalAggregates)
	}
	t.Logf("5000 candidates; warm candidate JSON aggregate never executed; execution_ms=%v", plans[0]["Execution Time"])
}
