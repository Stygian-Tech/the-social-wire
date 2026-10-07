package podcastcore

import "testing"

func TestFoundationPodcastDateTimezoneParity(t *testing.T) {
	for _, raw := range []string{"2026-10-05T00:00:00Z", "2026-10-05T00:00:00+0000", "2026-10-05T00:00:00+00", "2026-10-05T01:00:00+0100"} {
		if date, valid := ParseProgressDate(raw); !valid || date.UTC().Hour() != 0 {
			t.Fatal(raw, date, valid)
		}
		if rssDate(&raw) != raw || publishedDate(raw).Year() != 2026 {
			t.Fatal("catalog date lost", raw)
		}
	}
	fractional := "2026-10-05T00:00:00.123+0000"
	if _, valid := ParseProgressDate(fractional); !valid {
		t.Fatal("valid progress fraction rejected")
	}
	if rssDate(&fractional) != "1970-01-01T00:00:00Z" || publishedDate(fractional).Year() != 1970 {
		t.Fatal("catalog formatter must retain Swift non-fractional policy")
	}
	for _, raw := range []string{"20261005T000000Z", "2026-10-05 00:00:00Z", "2026-10-05T00:00Z", "2026-10-05T00:00:00"} {
		if _, valid := ParseProgressDate(raw); valid {
			t.Fatal("invalid progress date accepted", raw)
		}
	}
}
