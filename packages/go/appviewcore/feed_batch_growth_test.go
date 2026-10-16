package appviewcore

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"reflect"
	"sync/atomic"
	"testing"
	"time"
)

func TestFeedContinuationGrowsBatchesWithoutCappingHistory(t *testing.T) {
	var limits []int64
	var calls atomic.Int64
	db := sql.OpenDB(feedCountingConnector{Connector: batchDeadlineConnector{query: func(context.Context) (driver.Rows, error) {
		size := int(limits[len(limits)-1])
		if len(limits) == 6 {
			size--
		}
		return &sparseBatchRows{remaining: size, at: time.Now()}, nil
	}}, calls: &calls, batches: &limits})
	defer db.Close()
	page, err := (FeedStore{DB: db}).Feed(context.Background(), "viewer", "subscribed", "", "unread", "", 1, time.Now())
	if err != nil || page == nil || len(page.Response.Entries) != 0 || page.Response.Cursor != nil {
		t.Fatalf("exhaustion: %#v %v", page, err)
	}
	if !reflect.DeepEqual(limits, []int64{32, 64, 128, 256, 512, 512}) {
		t.Fatalf("unexpected continuation limits: %v", limits)
	}
	limits = nil
	calls.Store(0)
	page, err = (FeedStore{DB: db}).Feed(context.Background(), "viewer", "subscribed", "", "all", "", 1, time.Now())
	if err != nil || page == nil || len(page.Response.Entries) != 1 || calls.Load() != 1 || limits[0] != 32 {
		t.Fatalf("dense first page: %#v %v limits=%v", page, err, limits)
	}
}
