package socialdrafts

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"

	"github.com/stygian-tech/the-social-wire/packages/go/gatewaycore"
	"github.com/stygian-tech/the-social-wire/packages/go/socialdraftcore"
)

const MaximumUploadBytes int64 = 100 << 20
const prefix = "/xrpc/app.thesocialwire.socialDraft."

type Routes struct{ Service Service }

func (a Routes) Register(mux *http.ServeMux) {
	for _, name := range []string{"reserveAttachment", "uploadAttachment", "putManifest", "deleteManifest"} {
		mux.HandleFunc("POST "+prefix+name, a.handler(name))
	}
	for _, name := range []string{"getAttachment", "getManifest"} {
		mux.HandleFunc("GET "+prefix+name, a.handler(name))
	}
}

func (a Routes) handler(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "private, no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		auth, ok := gatewaycore.AuthContextFrom(r.Context())
		if !ok || strings.TrimSpace(auth.DID) == "" || auth.DID == gatewaycore.AnonymousDiscoveryDID {
			failure(w, 401, "Unauthorized", "Authentication required")
			return
		}
		if a.Service == nil {
			failure(w, 503, "Unavailable", "Private draft storage unavailable")
			return
		}
		var out any
		var err error
		switch name {
		case "reserveAttachment":
			var input socialdraftcore.ReserveInput
			if !decode(w, r, &input, "assetId", "name", "contentType", "byteLength", "sha256", "kind") {
				return
			}
			var asset socialdraftcore.Asset
			asset, err = a.Service.Reserve(r.Context(), auth.DID, input)
			out = map[string]any{"attachment": asset}
		case "uploadAttachment":
			if r.ContentLength < 0 {
				failure(w, 411, "LengthRequired", "Content-Length required")
				return
			}
			if r.ContentLength > MaximumUploadBytes {
				failure(w, 413, "Quota", "Attachment exceeds allowed size")
				return
			}
			if r.ContentLength == 0 || strings.TrimSpace(r.Header.Get("X-Social-Draft-Upload-Id")) == "" {
				failure(w, 400, "InvalidRequest", "Invalid attachment upload")
				return
			}
			media, _, e := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if e != nil || media != "application/octet-stream" {
				failure(w, 400, "InvalidRequest", "Binary attachment required")
				return
			}
			var asset socialdraftcore.Asset
			asset, err = a.Service.Upload(r.Context(), auth.DID, r.Header.Get("X-Social-Draft-Upload-Id"), http.MaxBytesReader(w, r.Body, r.ContentLength), r.ContentLength)
			out = map[string]any{"attachment": asset}
		case "getAttachment":
			id := r.URL.Query().Get("assetId")
			if id == "" {
				failure(w, 400, "InvalidRequest", "Attachment identifier required")
				return
			}
			var body io.ReadCloser
			var asset socialdraftcore.Asset
			body, asset, err = a.Service.Download(r.Context(), auth.DID, id)
			if err == nil {
				defer body.Close()
				w.Header().Set("Content-Type", asset.ContentType)
				w.Header().Set("Content-Length", strconv.FormatInt(asset.ByteLength, 10))
				w.WriteHeader(200)
				if _, e := io.Copy(w, body); e != nil {
					panic(http.ErrAbortHandler)
				}
				return
			}
		case "getManifest":
			id := r.URL.Query().Get("draftId")
			if id == "" {
				failure(w, 400, "InvalidRequest", "Draft identifier required")
				return
			}
			out, err = a.Service.Manifest(r.Context(), auth.DID, id)
		case "putManifest":
			var input socialdraftcore.PutManifestInput
			if !decode(w, r, &input, "draftId", "expectedRevision", "attachments") {
				return
			}
			out, err = a.Service.PutManifest(r.Context(), auth.DID, input)
		case "deleteManifest":
			var input struct {
				DraftID          string `json:"draftId"`
				ExpectedRevision int64  `json:"expectedRevision"`
			}
			if !decode(w, r, &input, "draftId", "expectedRevision") {
				return
			}
			out, err = a.Service.DeleteManifest(r.Context(), auth.DID, input.DraftID, input.ExpectedRevision)
		}
		if err != nil {
			serviceFailure(w, err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(out)
	}
}

func decode(w http.ResponseWriter, r *http.Request, out any, required ...string) bool {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		failure(w, 400, "InvalidRequest", "JSON body required")
		return false
	}
	body := http.MaxBytesReader(w, r.Body, 1<<20)
	raw, err := io.ReadAll(body)
	if err != nil || len(strings.TrimSpace(string(raw))) == 0 || strings.TrimSpace(string(raw))[0] != '{' {
		failure(w, 400, "InvalidRequest", "Invalid request body")
		return false
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil {
		failure(w, 400, "InvalidRequest", "Invalid request body")
		return false
	}
	for _, field := range required {
		if value, ok := fields[field]; !ok || strings.TrimSpace(string(value)) == "null" {
			failure(w, 400, "InvalidRequest", "Required request field missing")
			return false
		}
	}
	d := json.NewDecoder(strings.NewReader(string(raw)))
	d.DisallowUnknownFields()
	if d.Decode(out) != nil || d.Decode(new(any)) != io.EOF {
		failure(w, 400, "InvalidRequest", "Invalid request body")
		return false
	}
	return true
}
func serviceFailure(w http.ResponseWriter, err error) {
	status, code, message := 503, "Unavailable", "Private draft storage unavailable"
	switch {
	case errors.Is(err, socialdraftcore.ErrInvalid):
		status, code, message = 400, "InvalidRequest", "Invalid private draft request"
	case errors.Is(err, socialdraftcore.ErrNotFound):
		status, code, message = 404, "NotFound", "Private draft attachment or manifest not found"
	case errors.Is(err, socialdraftcore.ErrConflict):
		status, code, message = 409, "Conflict", "Private draft revision conflict"
	case errors.Is(err, socialdraftcore.ErrQuota):
		status, code, message = 413, "Quota", "Private draft quota exceeded"
	case errors.Is(err, socialdraftcore.ErrUploadPending):
		status, code, message = 409, "UploadPending", "Private draft attachment upload pending"
	}
	failure(w, status, code, message)
}
func failure(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": code, "message": message})
}
