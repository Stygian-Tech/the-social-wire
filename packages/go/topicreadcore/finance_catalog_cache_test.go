package topicreadcore

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
)

func TestFinanceCatalogCachePostgresAuthoritativeRowsAndPolicy(t *testing.T) {
	db := selectionDB(t)
	// A connection-local shadow table isolates this fixture from all shared corpus
	// and topic fixtures while exercising the production SQL unchanged.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TEMP TABLE finance_instruments(instrument_id text PRIMARY KEY,payload jsonb NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	write := func(id, name, kind string) {
		t.Helper()
		raw, _ := json.Marshal(financecore.Instrument{ID: id, Name: name, Kind: kind, IsActive: true, Aliases: []string{}, SectorIDs: []string{}})
		if _, err := db.Exec(`INSERT INTO finance_instruments(instrument_id,payload)VALUES($1,$2::jsonb)ON CONFLICT(instrument_id)DO UPDATE SET payload=EXCLUDED.payload`, id, raw); err != nil {
			t.Fatal(err)
		}
	}
	write("b", "Original", "stock")
	store := &FinanceStore{DB: db}
	phases := map[string]int{}
	ctx := WithFeedPhaseObserver(context.Background(), func(phase string, _ time.Duration) { phases[phase]++ })
	read := func() []financecore.Instrument {
		t.Helper()
		values, err := store.Catalog(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return values
	}
	values := read()
	if len(values) != 1 || values[0].Name != "Original" {
		t.Fatal(values)
	}
	values[0].Name = "caller mutation"
	values = read()
	if values[0].Name != "Original" || phases["catalog-cache-hit"] != 1 || phases["catalog-query-open"] != 1 {
		t.Fatal(values, phases)
	}
	oldStamp := store.catalogCache.stamp
	write("b", "Updated", "stock")
	// The payload query must not return a different rowset under an old probe.
	rows, err := db.QueryContext(ctx, financeCatalogPayloadQuery, oldStamp)
	if err != nil {
		t.Fatal(err)
	}
	if rows.Next() {
		t.Fatal("changed rows accepted under old stamp")
	}
	if err = rows.Err(); err != nil {
		t.Fatal(err)
	}
	rows.Close()
	values = read()
	if values[0].Name != "Updated" || store.catalogCache.stamp == oldStamp {
		t.Fatal(values)
	}
	write("a", "First", "stock")
	values = read()
	if len(values) != 2 || values[0].ID != "a" || values[1].ID != "b" {
		t.Fatal("insert/order", values)
	}
	write("crypto-fixture", "Crypto", "crypto")
	values = read()
	if len(values) != 2 {
		t.Fatal("crypto policy", values)
	}
	beforePolicy := store.catalogCache.policy
	store.Config.Policy = financecore.ProviderPolicy{CryptoEnabled: true}
	values = read()
	if len(values) != 3 || store.catalogCache.policy == beforePolicy {
		t.Fatal("policy change", values)
	}
	if _, err := db.Exec(`DELETE FROM finance_instruments WHERE instrument_id='b'`); err != nil {
		t.Fatal(err)
	}
	values = read()
	if len(values) != 2 || values[0].ID != "a" || values[1].ID != "crypto-fixture" {
		t.Fatal("delete", values)
	}
	if _, err := db.Exec(`DELETE FROM finance_instruments`); err != nil {
		t.Fatal(err)
	}
	values = read()
	if values == nil || len(values) != 0 {
		t.Fatal("empty", values)
	}
	previous := store.catalogCache
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := store.Catalog(canceled); !errors.Is(err, context.Canceled) || store.catalogCache != previous {
		t.Fatal("cancellation", err)
	}
	if _, err := db.Exec(`DROP TABLE finance_instruments`); err != nil {
		t.Fatal(err)
	}
	// Public-table access is deliberately denied by renaming the temp shadow into
	// an invalid schema shape: errors must not fall back to the decoded entry.
	if _, err := db.Exec(`CREATE TEMP TABLE finance_instruments(invalid text)`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Catalog(ctx); err == nil {
		t.Fatal("database failure reused cache")
	}
}

func TestFinanceCatalogCacheConcurrentWarmReads(t *testing.T) {
	db := selectionDB(t)
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TEMP TABLE finance_instruments(instrument_id text PRIMARY KEY,payload jsonb NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(financecore.Instrument{ID: "fixture", Name: "Fixture", Kind: "stock", IsActive: true, Aliases: []string{}, SectorIDs: []string{}})
	if _, err := db.Exec(`INSERT INTO finance_instruments VALUES('fixture',$1::jsonb)`, raw); err != nil {
		t.Fatal(err)
	}
	store := &FinanceStore{DB: db}
	ctx := context.Background()
	if _, err := store.Catalog(ctx); err != nil {
		t.Fatal(err)
	}
	var group sync.WaitGroup
	for i := 0; i < 20; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			values, err := store.Catalog(ctx)
			if err != nil || len(values) != 1 || values[0].Name != "Fixture" {
				t.Error(values, err)
			}
			if len(values) > 0 {
				values[0].Name = "local"
			}
		}()
	}
	group.Wait()
}

func TestFinanceCatalogCloneOwnsNullableAndCollectionFields(t *testing.T) {
	value := "original"
	original := []financecore.Instrument{{Exchange: &value, ExchangeName: &value, MIC: &value, ShareClassFIGI: &value, CompositeFIGI: &value, Currency: &value, TradingViewSymbol: &value, Aliases: []string{"alias"}, SectorIDs: []string{"sector"}}, {Aliases: []string{}, SectorIDs: []string{}}, {}}
	copy := cloneFinanceCatalog(original)
	for _, field := range []*string{copy[0].Exchange, copy[0].ExchangeName, copy[0].MIC, copy[0].ShareClassFIGI, copy[0].CompositeFIGI, copy[0].Currency, copy[0].TradingViewSymbol} {
		*field = "changed"
	}
	copy[0].Aliases[0] = "changed"
	copy[0].SectorIDs[0] = "changed"
	if value != "original" || original[0].Aliases[0] != "alias" || original[0].SectorIDs[0] != "sector" {
		t.Fatal("catalog clone shares mutable fields")
	}
	if copy[1].Aliases == nil || copy[1].SectorIDs == nil || copy[2].Aliases != nil || copy[2].SectorIDs != nil {
		t.Fatal("nil/empty changed")
	}
}

func TestFinanceCatalogCachePostgresOversizedEntryNotRetained(t *testing.T) {
	db := selectionDB(t)
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TEMP TABLE finance_instruments(instrument_id text PRIMARY KEY,payload jsonb NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(financecore.Instrument{ID: "large", Name: strings.Repeat("x", financeCatalogMaximumCacheBytes+1), Kind: "stock", IsActive: true, Aliases: []string{}, SectorIDs: []string{}})
	if _, err := db.Exec(`INSERT INTO finance_instruments VALUES('large',$1::jsonb)`, raw); err != nil {
		t.Fatal(err)
	}
	store := &FinanceStore{DB: db}
	values, err := store.Catalog(context.Background())
	if err != nil || len(values) != 1 || store.catalogCache != nil {
		t.Fatal("oversized catalog retained", err, len(values))
	}
}

func TestFinanceCatalogStampPreservesOrderedRowLimit(t *testing.T) {
	db := selectionDB(t)
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TEMP TABLE finance_instruments(instrument_id text PRIMARY KEY,payload jsonb NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO finance_instruments SELECT 'fixture-'||lpad(i::text,5,'0'),'{}'::jsonb FROM generate_series(1,50001)i`); err != nil {
		t.Fatal(err)
	}
	stamp := func() string {
		t.Helper()
		var count int
		var revision string
		if err := db.QueryRow(financeCatalogMetadataQuery).Scan(&count, &revision); err != nil || count != 50000 {
			t.Fatal(count, err)
		}
		return revision
	}
	original := stamp()
	if _, err := db.Exec(`UPDATE finance_instruments SET payload='{"outside":true}' WHERE instrument_id='fixture-50001'`); err != nil {
		t.Fatal(err)
	}
	if stamp() != original {
		t.Fatal("row outside previous 50000-row catalog changed identity")
	}
	if _, err := db.Exec(`UPDATE finance_instruments SET payload='{"inside":true}' WHERE instrument_id='fixture-00001'`); err != nil {
		t.Fatal(err)
	}
	updated := stamp()
	if updated == original {
		t.Fatal("row inside catalog mutation ignored")
	}
	if _, err := db.Exec(`DELETE FROM finance_instruments WHERE instrument_id='fixture-00001'`); err != nil {
		t.Fatal(err)
	}
	if stamp() == updated {
		t.Fatal("ordered rowset shift ignored")
	}
}
