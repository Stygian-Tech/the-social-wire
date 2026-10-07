package wireworkercore

import (
	"bytes"
	"context"
	"encoding/base32"
	"encoding/json"
	"errors"
	"github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type VerifiedPublicRecord struct {
	URI, RepoDID, Collection, RecordKey, CID, Revision, PDSBase string
	Record                                                      json.RawMessage
	ObservedAt                                                  time.Time
}
type PublicRecordVerification struct {
	Status, CID, Revision string
	ObservedAt            time.Time
	Record                *VerifiedPublicRecord
}
type PublicRecordVerifier interface {
	Verify(context.Context, string, *string) (PublicRecordVerification, error)
}
type HTTPPublicRecordVerifier struct {
	PDS  *thinappviewcore.PDSClient
	HTTP thinappviewcore.PublicGetter
	Now  func() time.Time
}

func (v HTTPPublicRecordVerifier) Verify(ctx context.Context, uri string, expected *string) (PublicRecordVerification, error) {
	parts := strings.Split(strings.TrimPrefix(uri, "at://"), "/")
	if !strings.HasPrefix(uri, "at://") || len(uri) > 2048 || len(parts) != 3 || !validPublicRecordKey(parts[2]) || (!strings.HasPrefix(parts[0], "did:plc:") && !strings.HasPrefix(parts[0], "did:web:")) {
		return PublicRecordVerification{}, errors.New("invalid public record reference")
	}
	supported := parts[1] == "site.standard.document" || parts[1] == "site.standard.entry" || parts[1] == "site.standard.publication" || parts[1] == "site.standard.graph.recommend"
	if !supported || (parts[1] == "site.standard.graph.recommend" && expected == nil) || (expected != nil && !validPublicCID(*expected)) {
		return PublicRecordVerification{}, errors.New("invalid public record reference")
	}
	if v.PDS == nil {
		return PublicRecordVerification{}, errors.New("PDS resolver unavailable")
	}
	base, err := v.PDS.Resolve(ctx, parts[0])
	if err != nil {
		return PublicRecordVerification{}, err
	}
	parsed, _ := url.Parse(base)
	if base == "" || parsed == nil || (parsed.Port() != "" && parsed.Port() != "443") {
		return PublicRecordVerification{}, errors.New("unsafe public record endpoint")
	}
	get := func(method string, query url.Values, limit int, missing bool) (map[string]any, error) {
		client := v.HTTP
		if client == nil {
			client = thinappviewcore.PublicHTTP{}
		}
		status, _, body, err := client.Get(ctx, base+"/xrpc/"+method+"?"+query.Encode(), http.Header{"Accept": []string{"application/json"}}, limit, 0)
		if err != nil {
			return nil, err
		}
		if len(body) > limit {
			return nil, errors.New("public record response too large")
		}
		if status == 429 || status >= 500 {
			return nil, errors.New("public record transient status")
		}
		var value map[string]any
		decoder := json.NewDecoder(bytes.NewReader(body))
		decoder.UseNumber()
		if err = decoder.Decode(&value); err != nil {
			return nil, errors.New("invalid public record response")
		}
		var trailing any
		if decoder.Decode(&trailing) != io.EOF {
			return nil, errors.New("invalid public record response")
		}
		if missing && (status == 400 || status == 404) && value["error"] == "RecordNotFound" {
			return nil, nil
		}
		if status != 200 || len(value) == 0 {
			return nil, errors.New("invalid public record response")
		}
		return value, nil
	}
	now := func() time.Time {
		if v.Now != nil {
			return v.Now()
		}
		return time.Now().UTC()
	}
	active := func() (bool, error) {
		value, err := get("com.atproto.sync.getRepoStatus", url.Values{"did": {parts[0]}}, 64*1024, false)
		if err != nil {
			return false, err
		}
		state, ok := value["active"].(bool)
		if !ok || value["did"] != parts[0] {
			return false, errors.New("invalid repo status")
		}
		return state, nil
	}
	commit := func() (string, string, error) {
		value, err := get("com.atproto.sync.getLatestCommit", url.Values{"did": {parts[0]}}, 64*1024, false)
		if err != nil {
			return "", "", err
		}
		rev, _ := value["rev"].(string)
		cid, _ := value["cid"].(string)
		if !ValidRecordRevision(rev) || !validPublicCID(cid) {
			return "", "", errors.New("invalid repo commit")
		}
		return cid, rev, nil
	}
	on, err := active()
	if err != nil {
		return PublicRecordVerification{}, err
	}
	if !on {
		return PublicRecordVerification{Status: "inactive", ObservedAt: now()}, nil
	}
	beforeCID, beforeRev, err := commit()
	if err != nil {
		return PublicRecordVerification{}, err
	}
	record, err := get("com.atproto.repo.getRecord", url.Values{"repo": {parts[0]}, "collection": {parts[1]}, "rkey": {parts[2]}}, 1024*1024, true)
	if err != nil {
		return PublicRecordVerification{}, err
	}
	afterCID, afterRev, err := commit()
	if err != nil {
		return PublicRecordVerification{}, err
	}
	if beforeCID != afterCID || beforeRev != afterRev {
		return PublicRecordVerification{}, errors.New("repository changed during verification")
	}
	on, err = active()
	if err != nil {
		return PublicRecordVerification{}, err
	}
	result := PublicRecordVerification{Revision: afterRev, ObservedAt: now()}
	if !on {
		result.Status = "inactive"
		return result, nil
	}
	if record == nil {
		result.Status = "absent"
		return result, nil
	}
	cid, _ := record["cid"].(string)
	value, ok := record["value"].(map[string]any)
	if record["uri"] != uri || !validPublicCID(cid) || !ok || value["$type"] != parts[1] {
		return PublicRecordVerification{}, errors.New("invalid verified record")
	}
	result.CID = cid
	if expected != nil && cid != *expected {
		result.Status = "changed"
		return result, nil
	}
	data, err := json.Marshal(value)
	if err != nil {
		return PublicRecordVerification{}, err
	}
	if err := readstatecore.VerifyRecordCIDWithLimit(data, cid, 1024*1024); err != nil {
		return PublicRecordVerification{}, errors.New("public record CID mismatch")
	}
	result.Status = "verified"
	result.Record = &VerifiedPublicRecord{URI: uri, RepoDID: parts[0], Collection: parts[1], RecordKey: parts[2], CID: cid, Revision: afterRev, PDSBase: base, Record: data, ObservedAt: now()}
	return result, nil
}
func validPublicCID(cid string) bool {
	if len(cid) != 59 || cid[0] != 'b' {
		return false
	}
	for _, c := range cid[1:] {
		if !strings.ContainsRune("abcdefghijklmnopqrstuvwxyz234567", c) {
			return false
		}
	}
	data, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(cid[1:]))
	return err == nil && len(data) == 36 && data[0] == 1 && data[1] == 0x71 && data[2] == 0x12 && data[3] == 0x20 && base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(data) == strings.ToUpper(cid[1:])
}
func validPublicRecordKey(key string) bool {
	if key == "" || len(key) > 512 || key == "." || key == ".." {
		return false
	}
	for _, c := range key {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("._~:-", c)) {
			return false
		}
	}
	return true
}
