package wireworkercore

import (
	"context"
	"encoding/json"
	"github.com/stygian-tech/the-social-wire/packages/go/readstatecore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

type verifierGetter struct {
	did, uri, cid string
	record        map[string]any
	commits       int
	changed       bool
	tampered      bool
}

func (g *verifierGetter) Get(_ context.Context, raw string, _ http.Header, _ int, _ int) (int, http.Header, []byte, error) {
	u, _ := url.Parse(raw)
	var value any
	switch {
	case u.Host == "plc.directory":
		value = map[string]any{"id": g.did, "service": []any{map[string]any{"id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://pds.socialwire.net"}}}
	case strings.HasSuffix(u.Path, "getRepoStatus"):
		value = map[string]any{"did": g.did, "active": true}
	case strings.HasSuffix(u.Path, "getLatestCommit"):
		g.commits++
		rev := "2222222222222"
		if g.changed && g.commits > 1 {
			rev = "3333333333333"
		}
		value = map[string]any{"rev": rev, "cid": g.cid}
	case strings.HasSuffix(u.Path, "getRecord"):
		record := g.record
		if g.tampered {
			record = map[string]any{"$type": "site.standard.document", "title": "tampered"}
		}
		value = map[string]any{"uri": g.uri, "cid": g.cid, "value": record}
	default:
		value = map[string]any{"error": "unexpected"}
	}
	body, _ := json.Marshal(value)
	return 200, nil, body, nil
}
func TestPublicVerifierCommitStabilityAndBodyCID(t *testing.T) {
	did := "did:plc:abcdefghijklmnopqrstuvwx"
	uri := "at://" + did + "/site.standard.document/rkey"
	record := map[string]any{"$type": "site.standard.document", "title": "Original", "extension": map[string]any{"counter": 1}}
	data, _ := json.Marshal(record)
	cid, err := readstatecore.RecordCID(data)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name                       string
		changed, tampered, success bool
	}{{"stable", false, false, true}, {"changed", true, false, false}, {"body mismatch", false, true, false}} {
		t.Run(test.name, func(t *testing.T) {
			getter := &verifierGetter{did: did, uri: uri, cid: cid, record: record, changed: test.changed, tampered: test.tampered}
			verifier := HTTPPublicRecordVerifier{PDS: &thinappviewcore.PDSClient{HTTP: getter}, HTTP: getter}
			result, err := verifier.Verify(context.Background(), uri, nil)
			if test.success {
				if err != nil || result.Status != "verified" {
					t.Fatalf("%#v %v", result, err)
				}
			} else if err == nil {
				t.Fatalf("accepted %#v", result)
			}
		})
	}
	if !validPublicCID(cid) || validPublicCID(strings.ToUpper(cid)) || validPublicRecordKey("../rkey") {
		t.Fatal("invalid reference admission")
	}
}

func TestPublicVerifierPreservesLargeDocumentCID(t *testing.T) {
	did := "did:plc:abcdefghijklmnopqrstuvwx"
	uri := "at://" + did + "/site.standard.document/rkey"
	record := map[string]any{"$type": "site.standard.document", "content": strings.Repeat("large document ", 6000)}
	data, _ := json.Marshal(record)
	cid, err := readstatecore.RecordCIDWithLimit(data, 1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	getter := &verifierGetter{did: did, uri: uri, cid: cid, record: record}
	verifier := HTTPPublicRecordVerifier{PDS: &thinappviewcore.PDSClient{HTTP: getter}, HTTP: getter}
	result, err := verifier.Verify(context.Background(), uri, nil)
	if err != nil || result.Status != "verified" {
		t.Fatalf("large record %s %v", result.Status, err)
	}
}
