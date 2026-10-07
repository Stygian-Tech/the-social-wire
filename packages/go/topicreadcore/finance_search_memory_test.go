package topicreadcore

import (
	"fmt"
	"testing"
	"unsafe"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
)

func TestFinanceSearchResultsReleaseCatalogTail(t *testing.T) {
	for _, count := range []int{0, 1, 50, 50000} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			catalog := make([]financecore.Instrument, count)
			for i := range catalog {
				catalog[i].ID = fmt.Sprint(i)
			}
			result := limitFinanceSearchResults(catalog)
			if len(result) != min(50, count) {
				t.Fatalf("result length %d", len(result))
			}
			if cap(result) > 50 {
				t.Fatalf("search retains %d catalog slots for %d results", cap(result), len(result))
			}
			for i := range result {
				if result[i].ID != catalog[i].ID {
					t.Fatal("search order changed")
				}
			}
			if len(result) > 0 {
				catalog[0].ID = "mutated catalog"
				if result[0].ID == catalog[0].ID {
					t.Fatal("cached results alias catalog storage")
				}
			}
		})
	}
}

var financeSearchBenchmarkResult []financecore.Instrument

func BenchmarkFinanceSearchResultRetention(b *testing.B) {
	catalog := make([]financecore.Instrument, 50000)
	b.ReportAllocs()
	for range b.N {
		financeSearchBenchmarkResult = limitFinanceSearchResults(catalog)
	}
	b.ReportMetric(float64(cap(financeSearchBenchmarkResult))*float64(unsafe.Sizeof(financecore.Instrument{})), "retained-backing-B")
}
