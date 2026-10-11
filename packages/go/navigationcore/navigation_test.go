package navigationcore

import (
	"strings"
	"testing"
)

func TestPseudonymIsolationAndBounds(t *testing.T) {
	secret := strings.Repeat("s", 32)
	a, err := ViewerKey(secret, "dev", "did:plc:one")
	if err != nil || len(a) != 64 {
		t.Fatal(a, err)
	}
	b, _ := ViewerKey(secret, "prod", "did:plc:one")
	c, _ := ViewerKey(secret, "dev", "did:plc:two")
	if a == b || a == c || strings.Contains(a, "did:") {
		t.Fatal("pseudonym isolation failed")
	}
	same, _ := ViewerKey(secret, "dev", "did:plc:one")
	if same != a {
		t.Fatal("window dedup unstable")
	}
	if _, err = ViewerKey("", "dev", "did:plc:one"); err == nil {
		t.Fatal("unkeyed fingerprint accepted")
	}
	for _, tab := range Tabs {
		if !ValidTab(tab) {
			t.Fatal(tab)
		}
	}
	for _, bad := range []string{"/social/messages?to=alice", "did:plc:one", "alice.test", ""} {
		if ValidTab(bad) {
			t.Fatal("unbounded tab accepted", bad)
		}
	}
}
