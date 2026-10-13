package edge

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func (c *Handler) sportsSource(w http.ResponseWriter, r *http.Request, now time.Time) {
	if r.Method != "POST" || r.URL.RawQuery != "" {
		respondBatchStatus(w, 400)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
	if err != nil {
		respondBatchStatus(w, 413)
		return
	}
	if r.Header.Get(wirecore.CorpusBodyDigestHeader) != wirecore.CorpusBodyDigest(body) {
		respondBatchStatus(w, 401)
		return
	}
	var q corpuscore.SportsSourceRequest
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&q) != nil || decoder.Decode(new(any)) != io.EOF || !corpuscore.ValidSportsSourceRequest(q) {
		respondBatchStatus(w, 400)
		return
	}
	store, ok := c.Store.(corpuscore.SportsSourceStore)
	if !ok {
		respondBatchError(w, corpuscore.ErrUnavailable)
		return
	}
	var cacheMu sync.Mutex
	catalogCache := ""
	ctx := corpuscore.WithQueryObserver(r.Context(), func(phase string, _ time.Duration) {
		if phase == "source-catalog-cache-hit" || phase == "source-catalog-cache-miss" {
			cacheMu.Lock()
			catalogCache = phase
			cacheMu.Unlock()
		}
	})
	value, err := store.SportsSource(ctx, q, now)
	cacheMu.Lock()
	if catalogCache != "" {
		w.Header().Set("X-Wire-Corpus-Catalog-Cache", catalogCache)
	}
	cacheMu.Unlock()
	if err != nil {
		respondBatchError(w, err)
		return
	}
	encoded, err := corpuscore.MarshalHTTP(value)
	if err != nil {
		respondBatchStatus(w, 500)
		return
	}
	var parts map[string]json.RawMessage
	_ = json.Unmarshal(encoded, &parts)
	candidateBytes, catalogBytes := len(parts["candidates"]), len(parts["catalog"])

	slog.Info("Sports source response serialized", "request_id", corpuscore.ValidSourceRequestID(w.Header().Get("X-Request-ID")), "family", "sports", "bytes", len(encoded), "candidate_bytes", candidateBytes, "catalog_bytes", catalogBytes)
	if len(encoded) > 8<<20 {
		respondBatchError(w, corpuscore.ErrUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Wire-Corpus-Contract", "3")
	w.WriteHeader(200)
	_, _ = w.Write(encoded)
}
