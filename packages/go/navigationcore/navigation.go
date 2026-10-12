// Package navigationcore records bounded, pseudonymous tab activity, never identities or URLs.
package navigationcore

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"math"
	"time"
)

var Tabs = []string{"home", "explore", "notifications", "messages", "bookmarks", "lists", "feeds", "saved", "archive", "wire", "circle", "finance", "sports", "subscribed", "following", "podcasts", "articles", "live-post", "livestream", "brand-accounts", "analytics", "profile", "content-calendar"}

func ValidTab(tab string) bool {
	for _, known := range Tabs {
		if tab == known {
			return true
		}
	}
	return false
}
func ViewerKey(secret, environment, did string) (string, error) {
	if len(secret) < 32 || did == "" {
		return "", errors.New("navigation telemetry fingerprint configuration unavailable")
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte("navigation:v1\x00" + environment + "\x00" + did))
	return hex.EncodeToString(mac.Sum(nil)), nil
}
func Record(ctx context.Context, db *sql.DB, secret, environment, did, tab, event string, duration float64, at time.Time) error {
	if !ValidTab(tab) || (event != "tab_open" && event != "tab_dwell") || math.IsNaN(duration) || math.IsInf(duration, 0) || duration < 0 || duration > 60000 || (event == "tab_open" && duration != 0) || (event == "tab_dwell" && duration == 0) {
		return errors.New("invalid navigation sample")
	}
	key, err := ViewerKey(secret, environment, did)
	if err != nil {
		return err
	}
	if db == nil {
		return errors.New("navigation database unavailable")
	}
	opens := 0
	if event == "tab_open" {
		opens = 1
	}
	budget, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	// Per-key/day totals are bounded even if a client sends excessive samples.
	_, err = db.ExecContext(budget, `INSERT INTO operations_tab_activity(environment,activity_day,viewer_key,tab,opens,dwell_ms) VALUES($1,($2::timestamptz AT TIME ZONE 'UTC')::date,$3,$4,$5,$6) ON CONFLICT(environment,activity_day,viewer_key,tab) DO UPDATE SET opens=LEAST(operations_tab_activity.opens+EXCLUDED.opens,10000),dwell_ms=LEAST(operations_tab_activity.dwell_ms+EXCLUDED.dwell_ms,86400000)`, environment, at, key, tab, opens, duration)
	return err
}
