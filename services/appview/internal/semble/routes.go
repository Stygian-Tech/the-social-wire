package semble

import (
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/semblecore"
	"net/http"
	"strconv"
)

type Routes struct{ Service semblecore.Service }

func (a Routes) Register(mux *http.ServeMux) {
	for _, kind := range []string{"collections", "collection", "connections"} {
		mux.HandleFunc("GET /v1/semble/"+kind, a.handler(kind))
	}
}
func (a Routes) handler(kind string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		auth, ok := gatewaycore.AuthContextFrom(r.Context())
		if !ok || auth.DID == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
			w.WriteHeader(401)
			json.NewEncoder(w).Encode(map[string]string{"error": "Unauthorized"})
			return
		}
		q := r.URL.Query()
		limit := 50
		if raw, present := q["limit"]; present {
			var e error
			limit, e = strconv.Atoi(raw[0])
			if e != nil || limit < 1 || limit > 100 {
				failure(w, semblecore.Invalid("`limit` must be between 1 and 100."))
				return
			}
		}
		var cursor *string
		if raw, present := q["cursor"]; present {
			cursor = &raw[0]
		}
		var out any
		var e error
		switch kind {
		case "collections":
			out, e = a.Service.Collections(r.Context(), auth.DID, cursor, limit)
		case "collection":
			input := q.Get("collectionUri")
			if input == "" {
				e = semblecore.Invalid("Query requires `collectionUri`.")
			} else {
				out, e = a.Service.Collection(r.Context(), auth.DID, input, cursor, limit)
			}
		case "connections":
			input := q.Get("url")
			if input == "" {
				e = semblecore.Invalid("Query requires `url`.")
			} else {
				out, e = a.Service.Connections(r.Context(), auth.DID, input, cursor, limit)
			}
		}
		if e != nil {
			failure(w, e)
			return
		}
		json.NewEncoder(w).Encode(out)
	}
}
func failure(w http.ResponseWriter, e error) {
	var typed *semblecore.Error
	if !errors.As(e, &typed) {
		typed = &semblecore.Error{Status: 502, Code: "semble_projection_failed", Message: "Semble public projection is unavailable.", Retryable: true}
	}
	w.WriteHeader(typed.Status)
	json.NewEncoder(w).Encode(typed)
}
