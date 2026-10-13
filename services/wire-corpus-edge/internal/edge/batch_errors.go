package edge

import (
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/corpuscore"
	"net/http"
)

func respondBatchStatus(w http.ResponseWriter, status int) {
	name := "InternalServerError"
	switch status {
	case 400, 413:
		name = "InvalidRequest"
	case 401:
		name = "Unauthorized"
	case 503:
		name = "UpstreamUnavailable"
	}
	writeJSON(w, status, map[string]string{"error": name}, false)
}

func respondBatchError(w http.ResponseWriter, err error) {
	if errors.Is(err, corpuscore.ErrModerationUnavailable) {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "ModerationUnavailable"}, false)
		return
	}
	if errors.Is(err, corpuscore.ErrUnavailable) || errors.Is(err, corpuscore.ErrContractMismatch) {
		respondBatchStatus(w, http.StatusServiceUnavailable)
		return
	}
	respondBatchStatus(w, http.StatusInternalServerError)
}

// Keep serialization failures on the new XRPC surface in its declared error contract.
func writeBatchItems(w http.ResponseWriter, response corpuscore.ItemsResponse) {
	body, err := corpuscore.MarshalHTTP(response)
	if err != nil {
		respondBatchStatus(w, http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Wire-Corpus-Contract", "3")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}
