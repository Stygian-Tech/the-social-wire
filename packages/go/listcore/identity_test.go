package listcore

import "testing"

func TestOfficialShareIdentityAndCursorIsolation(t *testing.T) {
	canonical := "at://did:plc:creator/app.standard-reader.list/abc"
	for _, raw := range []string{canonical, " https://standard-reader.app/l/did%3Aplc%3Acreator/abc?view=grid#title "} {
		identity, ok := ParseResolutionInput(raw)
		if !ok || identity.URI() != canonical {
			t.Fatalf("identity %q: %#v %v", raw, identity, ok)
		}
	}
	for _, raw := range []string{"https://evil.invalid/l/did:plc:creator/abc", "https://user@standard-reader.app/l/did:plc:creator/abc", "https://standard-reader.app:443/l/did:plc:creator/abc", "https://standard-reader.app/l/did:plc:creator/a%2Fb", "at://did:plc:creator/app.standard-reader.list/..", canonical + "?foo=bar"} {
		if _, ok := ParseResolutionInput(raw); ok {
			t.Fatalf("accepted %q", raw)
		}
	}
	list := List{URI: canonical, Publications: []string{"at://did:plc:creator/site.standard.publication/a"}, Users: []string{}}
	fingerprint := Fingerprint("did:plc:viewer", list, "all")
	continuation := "2026-10-06T00:00:00Z|at://did:plc:creator/site.standard.document/a"
	raw := EncodeCursor(&continuation, fingerprint)
	decoded, err := DecodeCursor(raw, fingerprint)
	if err != nil || decoded == nil || *decoded != continuation {
		t.Fatalf("roundtrip %v %v", decoded, err)
	}
	for _, other := range []string{Fingerprint("did:plc:other", list, "all"), Fingerprint("did:plc:viewer", list, "unread")} {
		if _, err := DecodeCursor(raw, other); err == nil {
			t.Fatal("cursor crossed viewer or filter")
		}
	}
	list.Users = append(list.Users, "did:plc:new-member")
	if _, err := DecodeCursor(raw, Fingerprint("did:plc:viewer", list, "all")); err == nil {
		t.Fatal("cursor crossed changed membership")
	}
}
