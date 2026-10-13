package edge

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wirecore"
)

func (c *Handler) financeSource(w http.ResponseWriter, r *http.Request, now time.Time) {
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
	var q corpuscore.FinanceSourceRequest
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&q) != nil || decoder.Decode(new(any)) != io.EOF || !corpuscore.ValidFinanceSourceRequest(q) {
		respondBatchStatus(w, 400)
		return
	}
	store, ok := c.Store.(corpuscore.FinanceSourceStore)
	if !ok {
		respondBatchError(w, corpuscore.ErrUnavailable)
		return
	}
	value, err := store.FinanceSource(r.Context(), q, now)
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
	var generation map[string]json.RawMessage
	_ = json.Unmarshal(parts["generation"], &generation)
	candidateBytes, instrumentBytes := len(generation["candidates"]), len(generation["instruments"])

	slog.Info("Finance source response serialized", "request_id", corpuscore.ValidSourceRequestID(w.Header().Get("X-Request-ID")), "family", "finance", "bytes", len(encoded), "candidate_bytes", candidateBytes, "instrument_bytes", instrumentBytes)
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
