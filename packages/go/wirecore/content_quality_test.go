package wirecore

import (
	"strings"
	"testing"
	"time"
)

func TestCanonicalURLPreservesSemanticQuery(t *testing.T) {
	cases := map[string]string{"http://EXAMPLE.com:80/story/?utm_source=newsletter&b=2&a=1#comments": "https://example.com/story?a=1&b=2", "https://example.com/search?q=a+b&empty=&flag": "https://example.com/search?empty=&flag&q=a+b", "https://EXAMPLE.com/a?utm_medium=social": "https://example.com/a"}
	for raw, want := range cases {
		got := Canonicalize(raw)
		if got == nil || got.CanonicalURL != want || len(got.CanonicalKey) != 68 {
			t.Fatalf("%s got %+v", raw, got)
		}
	}
	for _, raw := range []string{"ftp://example.com/a", "not a url", "https://user:pass@example.com/a"} {
		if Canonicalize(raw) != nil {
			t.Fatal("accepted", raw)
		}
	}
}
func TestCorpusTrustBindsCompleteTargetAndBody(t *testing.T) {
	secret := []byte(strings.Repeat("s", 32))
	now := time.Unix(1000, 0)
	digest := CorpusBodyDigest([]byte("body"))
	headers, err := SignCorpusRequest(secret, "appview", "get", "/v1/candidates?a=1", &digest, now, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyCorpusRequest(secret, "appview", "GET", "/v1/candidates?a=1", headers, now.Add(60*time.Second)); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{"/v1/candidates?a=2", "/v1/candidates"} {
		if VerifyCorpusRequest(secret, "appview", "GET", target, headers, now) == nil {
			t.Fatal("accepted altered target")
		}
	}
	changed := headers
	other := CorpusBodyDigest([]byte("altered"))
	changed.BodyDigest = &other
	if VerifyCorpusRequest(secret, "appview", "GET", "/v1/candidates?a=1", changed, now) == nil {
		t.Fatal("accepted altered body")
	}
	if VerifyCorpusRequest(secret, "appview", "GET", "/v1/candidates?a=1", headers, now.Add(61*time.Second)) == nil {
		t.Fatal("accepted expired signature")
	}
}
func TestCommercialAndSafetyRules(t *testing.T) {
	ad := AssessCommercial(ContentEvidence{CanonicalURL: "https://example.com/shop/new?ref=a&utm_source=b", Title: "#ad Buy now $10"})
	if ad.Classification != ProbableAd || ad.Score != 10.25 {
		t.Fatalf("assessment %+v", ad)
	}
	if IsExplicitAdultContent(ContentEvidence{Title: "A medical discussion about breasts"}) {
		t.Fatal("overclassified clinical text")
	}
	if !IsExplicitAdultContent(ContentEvidence{CanonicalURL: "https://cdn.donmai.us/a", TopicKeys: []string{"nude"}}) {
		t.Fatal("missed source-specific rule")
	}
	if TargetKindForURL("https://bsky.app/profile/a/post/b", false) != SocialPost || TargetKindForURL("https://status.example.com/a", false) != OperationalStatus {
		t.Fatal("target kind mismatch")
	}
}
func TestRegionalRankerKeepsMajorStories(t *testing.T) {
	if !ShouldDownrankAmericanPolitics([]string{"US_Pólitics"}, nil) {
		t.Fatal("normalization mismatch")
	}
	if ShouldDownrankAmericanPolitics([]string{"us-politics"}, []ReasonCode{BreakingStory}) {
		t.Fatal("downranked major news")
	}
}
