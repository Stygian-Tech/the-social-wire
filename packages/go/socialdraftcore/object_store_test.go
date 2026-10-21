package socialdraftcore

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/s3"
)

func TestS3SDKPrivateBinaryObject(t *testing.T) {
	var stored []byte
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/private/opaque-object" || r.Header.Get("Authorization") == "" {
			t.Errorf("unsigned or unexpected object request")
		}
		switch r.Method {
		case "PUT":
			if r.Header.Get("Content-Type") != "application/octet-stream" || r.Header.Get("x-amz-acl") != "" {
				t.Error("unexpected object exposure metadata")
			}
			stored, _ = io.ReadAll(r.Body)
			w.Header().Set("ETag", `"test"`)
			w.WriteHeader(200)
		case "GET":
			w.Write(stored)
		case "DELETE":
			stored = nil
			w.WriteHeader(204)
		default:
			t.Error("unexpected S3 method")
			w.WriteHeader(400)
		}
	}))
	defer server.Close()
	store := newS3Store(Config{Endpoint: server.URL, Bucket: "private", AccessKeyID: "test", SecretAccessKey: "test-secret", Region: "auto"}).(*s3Store)
	options := store.client.Options()
	options.HTTPClient = server.Client()
	store.client = s3.New(options)
	s := testCrypto(t)
	var encrypted bytes.Buffer
	plain := bytes.Repeat([]byte{0, 255, 128}, 40000)
	if e := s.encrypt(&encrypted, bytes.NewReader(plain), ownerA, assetA); e != nil {
		t.Fatal(e)
	}
	if e := store.Put(context.Background(), "opaque-object", bytes.NewReader(encrypted.Bytes()), int64(encrypted.Len())); e != nil {
		t.Fatal(e)
	}
	if bytes.Contains(stored, plain[:100]) {
		t.Fatal("plaintext in S3")
	}
	r, e := store.Get(context.Background(), "opaque-object")
	if e != nil {
		t.Fatal(e)
	}
	var downloaded bytes.Buffer
	e = s.decrypt(&downloaded, r, ownerA, assetA, int64(len(plain)))
	r.Close()
	if e != nil || !bytes.Equal(plain, downloaded.Bytes()) {
		t.Fatalf("S3 roundtrip: %v", e)
	}
	if e := store.Delete(context.Background(), "opaque-object"); e != nil || stored != nil {
		t.Fatalf("S3 delete: %v", e)
	}
}
