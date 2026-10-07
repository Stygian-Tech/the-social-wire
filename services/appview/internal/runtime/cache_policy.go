package runtime

import (
	"github.com/stygian-tech/the-social-wire/packages/go/publicationcore"
	"github.com/stygian-tech/the-social-wire/packages/go/thinappviewcore"
	"math"
	"strconv"
	"time"
)

func positiveDuration(raw string, fallback time.Duration) time.Duration {
	v, e := strconv.ParseFloat(raw, 64)
	if e != nil || math.IsNaN(v) || math.IsInf(v, 0) || v <= 0 || v > float64(math.MaxInt64)/float64(time.Second) {
		return fallback
	}
	return time.Duration(v * float64(time.Second))
}
func configureCachePolicy(env map[string]string, cache *publicationcore.CacheStore, projection *thinappviewcore.ProjectionCache) {
	if cache == nil {
		return
	}
	cache.SidebarFresh = positiveDuration(env["APPVIEW_SIDEBAR_CACHE_FRESH_SECONDS"], time.Hour)
	cache.SidebarHard = positiveDuration(env["APPVIEW_SIDEBAR_CACHE_HARD_SECONDS"], 6*time.Hour)
	cache.UnreadFresh = positiveDuration(env["APPVIEW_UNREAD_CACHE_FRESH_SECONDS"], 2*time.Minute)
	cache.UnreadHard = positiveDuration(env["APPVIEW_UNREAD_CACHE_HARD_SECONDS"], 15*time.Minute)
	projection.FirstPageFresh = positiveDuration(env["APPVIEW_FIRST_PAGE_CACHE_FRESH_SECONDS"], 5*time.Minute)
	projection.FirstPageHard = positiveDuration(env["APPVIEW_FIRST_PAGE_CACHE_HARD_SECONDS"], 30*time.Minute)
}
