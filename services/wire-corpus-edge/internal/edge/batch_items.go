package edge

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
	"io"
	"net/http"
	"sync"
	"time"
)

func (c *Handler) batchItems(w http.ResponseWriter, r *http.Request, now time.Time) {
	if r.Method != "POST" || r.URL.RawQuery != "" {
		respondBatchStatus(w, 400)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 32<<10))
	if err != nil {
		respondBatchStatus(w, 413)
		return
	}
	if r.Header.Get(wirecore.CorpusBodyDigestHeader) != wirecore.CorpusBodyDigest(body) {
		respondBatchStatus(w, 401)
		return
	}
	var input corpuscore.ItemsRequest
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(new(any)) != io.EOF || !corpuscore.ValidItemIDs(input.ItemIDs) {
		respondBatchStatus(w, 400)
		return
	}
	store, ok := c.Store.(corpuscore.BatchItemStore)
	if !ok {
		respondBatchError(w, corpuscore.ErrUnavailable)
		return
	}
	var timingMu sync.Mutex
	phases := map[string]time.Duration{}
	ctx := corpuscore.WithQueryObserver(r.Context(), func(phase string, elapsed time.Duration) {
		timingMu.Lock()
		phases[phase] += elapsed
		timingMu.Unlock()
	})
	items, err := store.Items(ctx, input.ItemIDs, now)
	timingMu.Lock()
	w.Header().Set("Server-Timing", fmt.Sprintf("db-acquisition;dur=%.3f, db-query;dur=%.3f", float64(phases["db-acquisition"])/float64(time.Millisecond), float64(phases["db-query"])/float64(time.Millisecond)))
	timingMu.Unlock()
	if err != nil {
		respondBatchError(w, err)
		return
	}
	result := make(map[string]corpuscore.Item, len(items))
	for _, item := range items {
		result[item.Item.ItemID] = item
	}
	writeBatchItems(w, corpuscore.ItemsResponse{Items: result})
}
