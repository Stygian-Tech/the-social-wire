package wireworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

const legacyQualification = `metadata.source='open_graph' AND metadata.status IN ('fresh','stale') AND num_nonnulls(metadata.title,metadata.description,metadata.image_url,metadata.site_name,metadata.author_name,metadata.published_at::text,metadata.icon_url)>=2`

func TestMetadataQualificationPreservesAllFieldMasksAndAdmission(t *testing.T) {
	db := generationDatabase(t)
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	id, _ := newGenerationID()
	prefix := "qualification-" + id + "-"
	_, err = tx.Exec(`INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at)
 SELECT $1||n,'https://fixture.example/'||n,'fixture.example','Fixture','Fixture article title',now(),now(),now()+interval '1 day' FROM generate_series(0,4479) n`, prefix)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(`INSERT INTO wire_link_metadata_cache(canonical_key,canonical_url,source,status,title,description,image_url,site_name,author_name,published_at,icon_url,stale_until)
 SELECT $1||(mask*35+s.ordinal*7+st.ordinal),'https://fixture.example/',s.source,st.status,
 CASE WHEN mask&1<>0 THEN '' END,CASE WHEN mask&2<>0 THEN 'description' END,
 CASE WHEN mask&4<>0 THEN 'image' END,CASE WHEN mask&8<>0 THEN 'site' END,
 CASE WHEN mask&16<>0 THEN 'author' END,CASE WHEN mask&32<>0 THEN now() END,
 CASE WHEN mask&64<>0 THEN 'icon' END, now()+interval '1 day'
 FROM generate_series(0,127) mask
 CROSS JOIN (VALUES(0,'pending'),(1,'standard_site'),(2,'open_graph'),(3,'embedded_card'),(4,'fallback'))s(ordinal,source)
 CROSS JOIN (VALUES(0,'pending'),(1,'fetching'),(2,'fresh'),(3,'stale'),(4,'negative'),(5,'retry'),(6,'failed'))st(ordinal,status)`, prefix)
	if err != nil {
		t.Fatal(err)
	}
	assertMetadataParity(t, tx, prefix)
	// Simulate pre-migration rows only in this transaction/session; never change
	// globally enabled triggers. Reads must preserve admission during backfill.
	if _, err = tx.Exec(`SET LOCAL session_replication_role='replica'`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(`UPDATE wire_link_metadata_cache SET open_graph_qualified=NULL WHERE canonical_key LIKE $1`, prefix+"%"); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(`SET LOCAL session_replication_role='origin'`); err != nil {
		t.Fatal(err)
	}
	assertMetadataParity(t, tx, prefix)
	var affected int
	if err = tx.QueryRow(`SELECT wire_backfill_metadata_qualification(13)`).Scan(&affected); err != nil || affected != 13 {
		t.Fatalf("bounded batch: %d %v", affected, err)
	}
	var remaining int
	if err = tx.QueryRow(`SELECT count(*) FROM wire_link_metadata_cache WHERE canonical_key LIKE $1 AND open_graph_qualified IS NULL`, prefix+"%").Scan(&remaining); err != nil || remaining != 4467 {
		t.Fatalf("remaining: %d %v", remaining, err)
	}
	if err = tx.QueryRow(`SELECT wire_backfill_metadata_qualification(5000)`).Scan(&affected); err != nil || affected != 4467 {
		t.Fatalf("resumed batch: %d %v", affected, err)
	}
	assertMetadataParity(t, tx, prefix)
	// Expiry is deliberately not precomputed: equality, NULL, expired and fresh
	// values still use the exact dynamic predicate, including SQL three-valued logic.
	for _, expiry := range []any{nil, time.Now().Add(-time.Hour), time.Now(), time.Now().Add(time.Hour)} {
		if _, err = tx.Exec(`UPDATE wire_link_metadata_cache SET stale_until=$2 WHERE canonical_key LIKE $1`, prefix+"%", expiry); err != nil {
			t.Fatal(err)
		}
		assertMetadataParity(t, tx, prefix)
	}
	if _, err = tx.Exec(`UPDATE wire_link_metadata_cache SET stale_until=now() WHERE canonical_key LIKE $1`, prefix+"%"); err != nil {
		t.Fatal(err)
	}
	assertMetadataParity(t, tx, prefix)
}

func assertMetadataParity(t *testing.T, tx *sql.Tx, prefix string) {
	t.Helper()
	var mismatches int
	err := tx.QueryRow(`SELECT count(*) FROM wire_link_metadata_cache metadata WHERE canonical_key LIKE $1 AND (
 (COALESCE(metadata.open_graph_qualified,`+legacyQualification+`) IS DISTINCT FROM (`+legacyQualification+`))
 OR ((COALESCE(metadata.open_graph_qualified,`+legacyQualification+`) AND metadata.stale_until>now()) IS DISTINCT FROM ((`+legacyQualification+`) AND metadata.stale_until>now())))`, prefix+"%").Scan(&mismatches)
	if err != nil || mismatches != 0 {
		t.Fatalf("qualification parity: %d %v", mismatches, err)
	}
	err = tx.QueryRow(`SELECT count(*) FROM wire_link_metadata_cache metadata WHERE canonical_key LIKE $1 AND
 EXISTS (SELECT 1 FROM wire_link_metadata_cache cached WHERE cached.canonical_key=metadata.canonical_key
   AND cached.open_graph_qualified=TRUE AND cached.stale_until>now()
   UNION ALL
   SELECT 1 FROM wire_link_metadata_cache metadata_legacy WHERE metadata_legacy.canonical_key=metadata.canonical_key
   AND metadata_legacy.open_graph_qualified IS NULL AND `+strings.ReplaceAll(legacyQualification, "metadata.", "metadata_legacy.")+`
   AND metadata_legacy.stale_until>now()) IS DISTINCT FROM COALESCE((`+legacyQualification+`) AND metadata.stale_until>now(),FALSE)`, prefix+"%").Scan(&mismatches)
	if err != nil || mismatches != 0 {
		t.Fatalf("compact read parity: %d %v", mismatches, err)
	}
}

func TestMetadataQualificationProtectsDirectWrites(t *testing.T) {
	db := generationDatabase(t)
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	id, _ := newGenerationID()
	key := "qualification-update-" + id
	if _, err = tx.Exec(`INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at)VALUES($1,'https://fixture.example/','fixture.example','Fixture','Fixture article title',now(),now(),now()+interval '1 day')`, key); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(`INSERT INTO wire_link_metadata_cache(canonical_key,canonical_url,source,status,title,description,open_graph_qualified)VALUES($1,'https://fixture.example/','open_graph','fresh','','description',false)`, key); err != nil {
		t.Fatal(err)
	}
	for _, update := range []string{
		`open_graph_qualified=false`, `open_graph_qualified=NULL`, `title=title`,
		`stale_until=now()-interval '1 day'`, `retry_after=now()+interval '1 hour'`,
		`description=NULL`, `image_url='image'`, `source='fallback'`, `source='open_graph'`,
		`status='fetching'`, `status='stale'`, `image_url=NULL`, `published_at=now()`,
	} {
		if _, err = tx.Exec(`UPDATE wire_link_metadata_cache SET `+update+` WHERE canonical_key=$1`, key); err != nil {
			t.Fatal(err)
		}
		assertMetadataParity(t, tx, key)
	}
	for _, batch := range []any{0, 5001, nil} {
		if _, err = tx.Exec(`SAVEPOINT invalid_batch`); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(`SELECT wire_backfill_metadata_qualification($1)`, batch); err == nil {
			t.Fatalf("accepted invalid batch %v", batch)
		}
		if _, err = tx.Exec(`ROLLBACK TO SAVEPOINT invalid_batch`); err != nil {
			t.Fatal(err)
		}
	}
}

func TestRepresentativeRetractionUsesNarrowIndex(t *testing.T) {
	db := generationDatabase(t)
	tx, err := db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	id, _ := newGenerationID()
	prefix := "representative-plan-" + id + "-"
	_, err = tx.Exec(`INSERT INTO wire_items(canonical_key,canonical_url,representative_uri,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at)
 SELECT $1||n,'https://fixture.example/'||n,'at://fixture/'||$1||n,'fixture.example','Fixture','Fixture article title',now(),now(),now()+interval '1 day' FROM generate_series(1,20000)n`, prefix)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(`ANALYZE wire_items`); err != nil {
		t.Fatal(err)
	}
	rows, err := tx.Query(`EXPLAIN (ANALYZE,BUFFERS) UPDATE wire_items SET updated_at=now() WHERE representative_uri=$1`, "at://fixture/"+prefix+"12345")
	if err != nil {
		t.Fatal(err)
	}
	var plan strings.Builder
	for rows.Next() {
		var line string
		if err = rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		fmt.Fprintln(&plan, line)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(plan.String(), "wire_items_representative_uri_idx") || strings.Contains(plan.String(), "Seq Scan on wire_items") {
		t.Fatal(plan.String())
	}
	t.Log(plan.String())
}

func TestQualifiedMetadataCompactReadPlan(t *testing.T) {
	db := generationDatabase(t)
	id, _ := newGenerationID()
	prefix := "qualification-plan-" + id + "-"
	_, err := db.Exec(`INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at)
 SELECT $1||n,'https://'||$1||'.example/'||n,'fixture.example','Fixture','Fixture article title',now(),now(),now()+interval '1 day' FROM generate_series(1,20000)n`, prefix)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Exec(`DELETE FROM wire_items WHERE canonical_key LIKE $1`, prefix+"%") })
	_, err = db.Exec(`INSERT INTO wire_link_metadata_cache(canonical_key,canonical_url,source,status,title,description,stale_until)
 SELECT $1||n,'https://fixture.example/','open_graph','fresh',repeat(md5(n::text),24),repeat(md5((n+1)::text),24),now()+interval '1 day' FROM generate_series(1,20000)n`, prefix)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(`VACUUM (ANALYZE) wire_link_metadata_cache`); err != nil {
		t.Fatal(err)
	}
	legacy := `SELECT count(*) FROM wire_link_metadata_cache metadata WHERE canonical_key LIKE $1 AND ` + legacyQualification + ` AND stale_until>now()`
	compact := `SELECT count(*) FROM (
 SELECT canonical_key FROM wire_link_metadata_cache metadata WHERE canonical_key LIKE $1 AND open_graph_qualified=TRUE AND stale_until>now()
 UNION ALL SELECT canonical_key FROM wire_link_metadata_cache metadata WHERE canonical_key LIKE $1 AND open_graph_qualified IS NULL AND ` + legacyQualification + ` AND stale_until>now()) admitted`
	var baseline, after planEvidence
	for _, stage := range []string{"visible", "churn"} {
		if stage == "churn" {
			if _, err = db.Exec(`UPDATE wire_link_metadata_cache SET retry_after=now() WHERE canonical_key LIKE $1 AND canonical_key LIKE '%0'`, prefix+"%"); err != nil {
				t.Fatal(err)
			}
		}
		for _, query := range []struct{ name, sql string }{{"legacy", legacy}, {"compact", compact}} {
			var count int
			if err = db.QueryRow(query.sql, prefix+"%").Scan(&count); err != nil || count != 20000 {
				t.Fatalf("%s result %d %v", query.name, count, err)
			}
			var raw []byte
			if err = db.QueryRow(`EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) `+query.sql, prefix+"%").Scan(&raw); err != nil {
				t.Fatal(err)
			}
			var plans []struct {
				Plan        planEvidence `json:"Plan"`
				ExecutionMS float64      `json:"Execution Time"`
			}
			if err = json.Unmarshal(raw, &plans); err != nil {
				t.Fatal(err)
			}
			evidence := plans[0].Plan
			t.Logf("%s %s: blocks=%d heap_fetches=%d elapsed_ms=%.3f", stage, query.name, evidence.Hit+evidence.Read, sumHeapFetches(evidence), plans[0].ExecutionMS)
			if query.name == "legacy" {
				baseline = evidence
			} else {
				after = evidence
				if !strings.Contains(string(raw), "wire_metadata_qualified_key_idx") || !strings.Contains(string(raw), "wire_metadata_qualification_pending_idx") {
					t.Fatal(string(raw))
				}
			}
		}
		if stage == "visible" && after.Hit+after.Read >= baseline.Hit+baseline.Read {
			t.Fatalf("compact visible plan did not reduce buffer accesses: %d >= %d", after.Hit+after.Read, baseline.Hit+baseline.Read)
		}
	}
}

type planEvidence struct {
	Hit   int            `json:"Shared Hit Blocks"`
	Read  int            `json:"Shared Read Blocks"`
	Heap  int            `json:"Heap Fetches"`
	Plans []planEvidence `json:"Plans"`
}

func sumHeapFetches(plan planEvidence) int {
	total := plan.Heap
	for _, child := range plan.Plans {
		total += sumHeapFetches(child)
	}
	return total
}

func TestGenerationMetadataQualificationMatchesLegacyCandidates(t *testing.T) {
	db := generationDatabase(t)
	at := time.Now().UTC()
	items := seedGenerationItems(t, db, at)
	// Qualifying, expired, equality, NULL expiry, insufficient fields, and
	// fetching metadata cover every effective admission outcome in ranking.
	for i, item := range items {
		expiry := any(at.Add(time.Hour))
		source, status, title, description := "open_graph", "fresh", "Fixture title", "description"
		switch i {
		case 1:
			expiry = at.Add(-time.Second)
		case 2:
			expiry = at
		case 3:
			expiry = nil
		case 4:
			description = ""
			status = "pending"
		case 5:
			status = "fetching"
		}
		if _, err := db.Exec(`INSERT INTO wire_link_metadata_cache(canonical_key,canonical_url,source,status,title,description,stale_until)VALUES($1,$2,$3,$4,$5,$6,$7)`, item.CanonicalKey, item.CanonicalURL, source, status, title, description, expiry); err != nil {
			t.Fatal(err)
		}
	}
	material, err := os.ReadFile("testdata/metadata-legacy-candidates.sql")
	if err != nil {
		t.Fatal(err)
	}
	// A repeatable-read snapshot protects the exact full rows/order against other
	// package fixtures sharing the disposable canonical test database.
	tx, err := db.BeginTx(context.Background(), &sql.TxOptions{Isolation: sql.LevelRepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	for _, query := range []string{candidateQuery, projectedCandidateQuery} {
		for _, language := range []string{"und", "en"} {
			for _, external := range []bool{false, true} {
				args := []any{external, at, at.Add(-72 * time.Hour), language, 5000}
				var before, after string
				if err = tx.QueryRow(`SELECT COALESCE(jsonb_agg(to_jsonb(selected)),'[]'::jsonb)::text FROM (`+string(material)+`)selected`, args...).Scan(&before); err != nil {
					t.Fatal(err)
				}
				if err = tx.QueryRow(`SELECT COALESCE(jsonb_agg(to_jsonb(selected)),'[]'::jsonb)::text FROM (`+query+`)selected`, args...).Scan(&after); err != nil {
					t.Fatal(err)
				}
				if before != after {
					t.Fatalf("candidate parity changed language=%s external=%v", language, external)
				}
			}
		}
	}
}

func TestMetadataQualificationBackfillSkipsLockedSourceWrites(t *testing.T) {
	db := generationDatabase(t)
	for _, mutate := range []bool{false, true} {
		id, _ := newGenerationID()
		prefix := "qualification-lock-" + id + "-"
		seed, err := db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		_, err = seed.Exec(`INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at)
  SELECT $1||n,'https://'||$1||'.example/'||n,'fixture.example','Fixture','Fixture article title',now(),now(),now()+interval '1 day' FROM generate_series(1,2)n`, prefix)
		if err != nil {
			seed.Rollback()
			t.Fatal(err)
		}
		_, err = seed.Exec(`INSERT INTO wire_link_metadata_cache(canonical_key,canonical_url,source,status,title,description,stale_until)
  SELECT $1||n,'https://fixture.example/','open_graph','fresh','title','description',now()+interval '1 day' FROM generate_series(1,2)n`, prefix)
		if err != nil {
			seed.Rollback()
			t.Fatal(err)
		}
		if _, err = seed.Exec(`SET LOCAL session_replication_role='replica'`); err != nil {
			seed.Rollback()
			t.Fatal(err)
		}
		if _, err = seed.Exec(`UPDATE wire_link_metadata_cache SET open_graph_qualified=NULL WHERE canonical_key LIKE $1`, prefix+"%"); err != nil {
			seed.Rollback()
			t.Fatal(err)
		}
		if err = seed.Commit(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { db.Exec(`DELETE FROM wire_items WHERE canonical_key LIKE $1`, prefix+"%") })
		writer, err := db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		if _, err = writer.Exec(`SELECT canonical_key FROM wire_link_metadata_cache WHERE canonical_key=$1 FOR UPDATE`, prefix+"1"); err != nil {
			writer.Rollback()
			t.Fatal(err)
		}
		var affected int
		if err = db.QueryRow(`SELECT wire_backfill_metadata_qualification(500)`).Scan(&affected); err != nil || affected != 1 {
			writer.Rollback()
			t.Fatalf("locked batch %d %v", affected, err)
		}
		if mutate {
			if _, err = writer.Exec(`UPDATE wire_link_metadata_cache SET title=NULL WHERE canonical_key=$1`, prefix+"1"); err != nil {
				writer.Rollback()
				t.Fatal(err)
			}
		}
		if err = writer.Commit(); err != nil {
			t.Fatal(err)
		}
		expected := 1
		if mutate {
			expected = 0
		}
		if err = db.QueryRow(`SELECT wire_backfill_metadata_qualification(500)`).Scan(&affected); err != nil || affected != expected {
			t.Fatalf("resumed batch %d want %d %v", affected, expected, err)
		}
		check, err := db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		assertMetadataParity(t, check, prefix)
		check.Rollback()
	}
}
