package corpuscore

import (
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestPostgresFinanceSourceViewsLegacyParityAndCurrentGates(t *testing.T) {
	db := corpusDB(t)
	applySportsSourceViews(t, db)
	now := time.Now().UTC()
	id := "d7110000-3333-3333-3333-333333333333"
	keys := []string{"finance-source-view-a", "finance-source-view-b"}
	instruments := []string{"finance-view-reference-a", "finance-view-reference-b", "finance-view-unreferenced"}
	t.Cleanup(func() {
		db.Exec(`DELETE FROM finance_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM finance_instruments WHERE instrument_id=ANY($1::text[])`, instruments)
		db.Exec(`DELETE FROM wire_items WHERE canonical_key=ANY($1::text[])`, keys)
	})
	for _, key := range keys {
		execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code)VALUES($1,'https://example.test/'||$1,'example.test','Fixture','Fixture',$2,$2,$3,'en')`, key, now, now.Add(time.Hour))
	}
	for _, instrument := range instruments {
		execFixture(t, db, `INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)VALUES($1,$1,jsonb_build_object('id',$1::text,'name','Original'),$2)`, instrument, now)
	}
	candidate := func(key string, refs ...string) map[string]any {
		associations := []map[string]string{}
		for _, ref := range refs {
			associations = append(associations, map[string]string{"instrumentID": ref})
		}
		return map[string]any{"item": map[string]string{"itemId": key}, "analysis": map[string]any{"associations": associations}}
	}
	payload, _ := json.Marshal([]map[string]any{candidate(keys[0], instruments[0]), candidate(keys[1], instruments[1]), candidate(keys[0], instruments[0], instruments[1], instruments[0])})
	execFixture(t, db, `INSERT INTO finance_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'en','fixture',$2,$3,$4::jsonb,FALSE)`, id, now, now.Add(time.Hour), payload)
	parity := func(ordinals []int, refs []string) {
		t.Helper()
		var oldItems, oldInstruments, newItems, newInstruments []byte
		if err := db.QueryRow(`SELECT payload::text,instruments::text FROM wire_serving.finance_generations WHERE generation_id=$1::uuid`, id).Scan(&oldItems, &oldInstruments); err != nil {
			t.Fatal(err)
		}
		if err := db.QueryRow(`SELECT COALESCE(jsonb_agg(candidate ORDER BY ordinal),'[]'::jsonb)::text FROM wire_serving.finance_source_candidates WHERE generation_id=$1::uuid`, id).Scan(&newItems); err != nil {
			t.Fatal(err)
		}
		if err := db.QueryRow(`SELECT COALESCE(jsonb_agg(payload ORDER BY instrument_id),'[]'::jsonb)::text FROM wire_serving.finance_source_instruments WHERE generation_id=$1::uuid`, id).Scan(&newInstruments); err != nil {
			t.Fatal(err)
		}
		for _, pair := range [][2][]byte{{oldItems, newItems}, {oldInstruments, newInstruments}} {
			var old, current any
			json.Unmarshal(pair[0], &old)
			json.Unmarshal(pair[1], &current)
			if !reflect.DeepEqual(old, current) {
				t.Fatal("legacy parity", string(pair[0]), string(pair[1]))
			}
		}
		actualOrd := []int{}
		rows, err := db.Query(`SELECT ordinal FROM wire_serving.finance_source_candidates WHERE generation_id=$1::uuid ORDER BY ordinal`, id)
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			var value int
			if err = rows.Scan(&value); err != nil {
				t.Fatal(err)
			}
			actualOrd = append(actualOrd, value)
		}
		if err = rows.Err(); err != nil {
			t.Fatal(err)
		}
		rows.Close()
		if !reflect.DeepEqual(actualOrd, ordinals) {
			t.Fatal(actualOrd, ordinals)
		}
		actualRefs := []string{}
		rows, err = db.Query(`SELECT instrument_id FROM wire_serving.finance_source_instruments WHERE generation_id=$1::uuid ORDER BY instrument_id`, id)
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			var value string
			if err = rows.Scan(&value); err != nil {
				t.Fatal(err)
			}
			actualRefs = append(actualRefs, value)
		}
		if err = rows.Err(); err != nil {
			t.Fatal(err)
		}
		rows.Close()
		if !reflect.DeepEqual(actualRefs, refs) {
			t.Fatal(actualRefs, refs)
		}
		var stamp string
		if err = db.QueryRow(`SELECT cache_revision FROM wire_serving.finance_source_heads WHERE generation_id=$1::uuid`, id).Scan(&stamp); err != nil || len(strings.Split(stamp, ":")) != 3 {
			t.Fatal(stamp, err)
		}
	}
	refs := instruments[:2]
	parity([]int{1, 2, 3}, refs)
	for _, change := range []string{`eligible=FALSE`, `expires_at=CURRENT_TIMESTAMP-INTERVAL '1 hour'`, `target_kind='social_post'`, `commercial_class='probable_ad'`, `language_code='fr'`} {
		execFixture(t, db, `UPDATE wire_items SET `+change+` WHERE canonical_key=$1`, keys[0])
		parity([]int{2}, refs)
		execFixture(t, db, `UPDATE wire_items SET eligible=TRUE,expires_at=$2,target_kind='external_article',commercial_class='normal',language_code='en' WHERE canonical_key=$1`, keys[0], now.Add(time.Hour))
	}
	for _, label := range []string{"block", "exclude", "adult", "graphic", "spam"} {
		execFixture(t, db, `INSERT INTO wire_labels(canonical_key,label_key,label_value,source,applied_at,expires_at)VALUES($1,$2,$2,'fixture',$3,$4)`, keys[0], label, now, now.Add(time.Hour))
		parity([]int{2}, refs)
		execFixture(t, db, `DELETE FROM wire_labels WHERE canonical_key=$1`, keys[0])
	}
	var before, after string
	if err := db.QueryRow(`SELECT cache_revision FROM wire_serving.finance_source_instruments WHERE generation_id=$1::uuid AND instrument_id=$2`, id, instruments[0]).Scan(&before); err != nil {
		t.Fatal(err)
	}
	execFixture(t, db, `UPDATE finance_instruments SET payload=payload||'{"name":"Updated"}'::jsonb WHERE instrument_id=$1`, instruments[0])
	parity([]int{1, 2, 3}, refs)
	if err := db.QueryRow(`SELECT cache_revision FROM wire_serving.finance_source_instruments WHERE generation_id=$1::uuid AND instrument_id=$2`, id, instruments[0]).Scan(&after); err != nil || before == after {
		t.Fatal("instrument mutation stamp", before, after, err)
	}
	execFixture(t, db, `DELETE FROM finance_instruments WHERE instrument_id=$1`, instruments[0])
	parity([]int{1, 2, 3}, instruments[1:2])
	execFixture(t, db, `UPDATE wire_items SET language_code='fr' WHERE canonical_key=$1`, keys[0])
	execFixture(t, db, `UPDATE finance_generations SET language='und' WHERE generation_id=$1::uuid`, id)
	parity([]int{1, 2, 3}, instruments[1:2])
	execFixture(t, db, `DELETE FROM wire_items WHERE canonical_key=ANY($1::text[])`, keys)
	parity([]int{}, instruments[1:2]) // RAW references survive today's item removals.
	execFixture(t, db, `UPDATE finance_generations SET payload='[]' WHERE generation_id=$1::uuid`, id)
	parity([]int{}, []string{})
	execFixture(t, db, `UPDATE finance_generations SET expires_at=$2 WHERE generation_id=$1::uuid`, id, now.Add(-time.Hour))
	for _, view := range []string{"finance_generations", "finance_source_heads", "finance_source_candidates", "finance_source_instruments"} {
		var count int
		if err := db.QueryRow(`SELECT count(*) FROM wire_serving.`+view+` WHERE generation_id=$1::uuid`, id).Scan(&count); err != nil || count != 0 {
			t.Fatal("expired generation", view, count, err)
		}
	}
}

func TestPostgresFinanceSourceWarmPlanSkipsBothFullPayloadArrays(t *testing.T) {
	db := corpusDB(t)
	applySportsSourceViews(t, db)
	now := time.Now().UTC()
	id := "d7110000-4444-4444-4444-444444444444"
	key := "finance-source-view-plan-"
	prefix := "finance-view-plan-"
	t.Cleanup(func() {
		db.Exec(`DELETE FROM finance_generations WHERE generation_id=$1::uuid`, id)
		db.Exec(`DELETE FROM finance_instruments WHERE provider_key LIKE $1`, prefix+"%")
		db.Exec(`DELETE FROM wire_items WHERE canonical_key LIKE $1`, key+"%")
	})
	execFixture(t, db, `INSERT INTO wire_items(canonical_key,canonical_url,source_domain,source_name,title,first_seen_at,last_seen_at,expires_at,language_code)SELECT $1::text||i::text,'https://example.test/'||$1::text||i::text,'example.test','Fixture','Fixture',$2,$2,$3,'xx' FROM generate_series(1,5000)i`, key, now, now.Add(time.Hour))
	execFixture(t, db, `INSERT INTO finance_instruments(instrument_id,provider_key,payload,updated_at)SELECT $1::text||lpad(i::text,5,'0'),$1::text||lpad(i::text,5,'0'),jsonb_build_object('id',$1::text||lpad(i::text,5,'0'),'name','Fixture','symbol','FIX','kind','stock','providerID',$1::text||lpad(i::text,5,'0'),'aliases','[]'::jsonb,'sectorIDs','[]'::jsonb,'isActive',true),$2 FROM generate_series(1,5000)i`, prefix, now)
	base := financeSourceFixture().Generation.Candidates[0]
	summary := strings.Repeat("x", 512)
	base.Item.ItemID = key
	base.Item.Summary = &summary
	candidates := make([]financecore.RankCandidate, 5000)
	for i := range candidates {
		value := base
		value.Item.ItemID = fmt.Sprintf("%s%d", key, i+1)
		value.Analysis.Associations = []financecore.Association{{InstrumentID: fmt.Sprintf("%s%05d", prefix, i+1), Confidence: 1, ResolverVersion: financecore.ResolverVersion, Evidence: []string{"fixture"}}}
		candidates[i] = value
	}
	payload, err := MarshalHTTP(candidates)
	if err != nil {
		t.Fatal(err)
	}
	var instrumentBytes int
	if err = db.QueryRow(`SELECT COALESCE(sum(length(payload::text)),0) FROM finance_instruments WHERE provider_key LIKE $1`, prefix+"%").Scan(&instrumentBytes); err != nil {
		t.Fatal(err)
	}
	if len(payload)+instrumentBytes >= 8<<20 {
		t.Fatal("representative full generation exceeds producer budget", len(payload), instrumentBytes)
	}
	execFixture(t, db, `INSERT INTO finance_generations(generation_id,source_generation_id,language,algorithm_version,generated_at,expires_at,payload,is_active)VALUES($1::uuid,$1::uuid,'xx','plan-fixture',$2,$3,$4::jsonb,TRUE)`, id, now, now.Add(time.Hour), payload)

	var revision string
	if err := db.QueryRow(financeSourceProjection+`SELECT revision FROM current_source`, "xx", now).Scan(&revision); err != nil {
		t.Fatal(err)
	}
	query := financeSourceProjection + `SELECT generation_id,generated_at,expires_at,revision,CASE WHEN generation_id::text=$3 AND revision=$4 THEN NULL ELSE ` + financeSourceCandidatePayload + ` END,CASE WHEN generation_id::text=$3 AND revision=$4 THEN NULL ELSE ` + financeSourceInstrumentPayload + ` END FROM current_source`
	var raw []byte
	if err := db.QueryRow(`EXPLAIN(ANALYZE,VERBOSE,FORMAT JSON) `+query, "xx", now, id, revision).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var plans []map[string]any
	if err := json.Unmarshal(raw, &plans); err != nil {
		t.Fatal(err)
	}
	fullAggregates := 0
	itemIndexLoops := 0.0
	var walk func(map[string]any)
	walk = func(node map[string]any) {
		if node["Relation Name"] == "wire_items" {
			if node["Node Type"] == "Seq Scan" && node["Actual Loops"].(float64) > 0 {
				t.Fatal("source eligibility scanned broad wire_items corpus")
			}
			if node["Node Type"] == "Index Scan" || node["Node Type"] == "Index Only Scan" {
				itemIndexLoops += node["Actual Loops"].(float64)
			}
		}

		if elapsed, ok := node["Actual Total Time"].(float64); ok && elapsed > 50 {
			t.Logf("plan node=%v relation=%v alias=%v loops=%v rows=%v total_ms=%v", node["Node Type"], node["Relation Name"], node["Alias"], node["Actual Loops"], node["Actual Rows"], elapsed)
		}
		output, _ := json.Marshal(node["Output"])
		if node["Node Type"] == "Aggregate" && strings.Contains(string(output), "jsonb_agg") && (strings.Contains(string(output), ".candidate") || strings.Contains(string(output), ".payload")) {
			fullAggregates++
			if node["Actual Loops"].(float64) != 0 {
				t.Fatal("warm full payload aggregate executed", string(output))
			}
		}
		children, _ := node["Plans"].([]any)
		for _, child := range children {
			walk(child.(map[string]any))
		}
	}
	walk(plans[0]["Plan"].(map[string]any))
	if itemIndexLoops != 5000 {
		t.Fatal("source eligibility did not use parameterized item indexes")
	}
	if fullAggregates != 2 {
		t.Fatal("expected guarded full candidate/instrument aggregates", fullAggregates)
	}
	t.Logf("5000 candidates and referenced instruments; full_body_bytes=%d; warm full arrays never executed; execution_ms=%v", len(payload)+instrumentBytes, plans[0]["Execution Time"])
}
