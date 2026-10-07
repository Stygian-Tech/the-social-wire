package thinappviewcore

import (
	"net/url"
	"testing"
)

func TestPublicationIconPreservesPublisherFormatAndAvoidsBridgyBlobs(t *testing.T) {
	record := map[string]any{"icon": map[string]any{"ref": map[string]any{"$link": "bafykfixture"}}, "logoUrl": "https://publisher.invalid/logo.png"}
	if icon := PublicationIconURL(record, "did:plc:fixture", "https://atproto.brid.gy"); icon == nil || *icon != "https://publisher.invalid/logo.png" {
		t.Fatalf("fallback lost: %v", icon)
	}
	icon := PublicationIconURL(record, "did:plc:fixture", "https://pds.invalid/")
	if icon == nil {
		t.Fatal("blob icon missing")
	}
	u, err := url.Parse(*icon)
	if err != nil || u.Path != "/xrpc/com.atproto.sync.getBlob" || u.Query().Get("did") != "did:plc:fixture" || u.Query().Get("cid") != "bafykfixture" {
		t.Fatalf("bad blob URL: %v %v", icon, err)
	}
	record["icon"] = "https://publisher.invalid/logo.gif"
	if icon := PublicationIconURL(record, "did:plc:fixture", "https://pds.invalid"); icon == nil || *icon != "https://publisher.invalid/logo.gif" {
		t.Fatalf("publisher format changed: %v", icon)
	}
}
