package analyticscore

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

var ErrRateLimit = errors.New("analytics daily observation limit reached")

type Store struct {
	DB     *sql.DB
	Secret string
}

func (s Store) Save(ctx context.Context, author string, items []Item, complete bool, now time.Time) error {
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,1))`, author); e != nil {
		return e
	}
	var previous time.Time
	e = tx.QueryRowContext(ctx, `SELECT refreshed_at FROM creator_analytics_refresh WHERE author_did=$1`, author).Scan(&previous)
	if e != nil && e != sql.ErrNoRows {
		return e
	}
	if previous.After(now) {
		return nil
	}
	if complete {
		subjects := make([]string, 0, len(items))
		for _, it := range items {
			subjects = append(subjects, it.URI)
		}
		if _, e = tx.ExecContext(ctx, `DELETE FROM creator_analytics_items WHERE author_did=$1 AND NOT(subject_uri=ANY($2::text[]))`, author, subjects); e != nil {
			return e
		}
	}
	for _, it := range items {
		raw, e := json.Marshal(it)
		if e != nil {
			return e
		}
		if _, e = tx.ExecContext(ctx, `INSERT INTO creator_analytics_items(author_did,subject_uri,item_json,refreshed_at) VALUES($1,$2,$3,$4) ON CONFLICT(author_did,subject_uri) DO UPDATE SET item_json=EXCLUDED.item_json,refreshed_at=EXCLUDED.refreshed_at`, author, it.URI, raw, now); e != nil {
			return e
		}
		if it.Engagement != nil {
			g := it.Engagement
			if _, e = tx.ExecContext(ctx, `INSERT INTO creator_analytics_snapshots(author_did,subject_uri,day,likes,replies,reposts,quotes) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(author_did,subject_uri,day) DO UPDATE SET likes=EXCLUDED.likes,replies=EXCLUDED.replies,reposts=EXCLUDED.reposts,quotes=EXCLUDED.quotes`, author, it.URI, now.UTC().Format("2006-01-02"), g.Likes, g.Replies, g.Reposts, g.Quotes); e != nil {
				return e
			}
		}
	}
	if _, e = tx.ExecContext(ctx, `INSERT INTO creator_analytics_refresh(author_did,refreshed_at,inventory_complete) VALUES($1,$2,$3) ON CONFLICT(author_did) DO UPDATE SET refreshed_at=EXCLUDED.refreshed_at,inventory_complete=EXCLUDED.inventory_complete`, author, now, complete); e != nil {
		return e
	}
	return tx.Commit()
}
func (s Store) Record(ctx context.Context, viewer, author string, event Event, now time.Time) error {
	if viewer == author {
		return nil
	}
	if len(s.Secret) < 32 {
		return errors.New("analytics pseudonym key unavailable")
	}
	day := now.UTC().Format("2006-01-02")
	mac := hmac.New(sha256.New, []byte(s.Secret))
	mac.Write([]byte("creator-analytics\x00" + day + "\x00" + viewer))
	key := hex.EncodeToString(mac.Sum(nil))
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, key); e != nil {
		return e
	}
	var count int
	if e = tx.QueryRowContext(ctx, `SELECT count(*) FROM creator_analytics_events WHERE day=$1 AND viewer_key=$2`, day, key).Scan(&count); e != nil {
		return e
	}
	if count >= 1000 {
		return ErrRateLimit
	}
	if event.Event == "outbound_click" {
		var seen bool
		if e = tx.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM creator_analytics_events WHERE day=$1 AND viewer_key=$2 AND subject_uri=$3 AND event='impression')`, day, key, event.SubjectURI).Scan(&seen); e != nil {
			return e
		}
		if !seen {
			return nil
		}
	}
	result, e := tx.ExecContext(ctx, `INSERT INTO creator_analytics_events(author_did,subject_uri,day,viewer_key,event,surface) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING`, author, event.SubjectURI, day, key, event.Event, event.Surface)
	if e != nil {
		return e
	}
	inserted, e := result.RowsAffected()
	if e != nil {
		return e
	}
	if inserted == 0 {
		return tx.Commit()
	}
	impressions, views, clicks := 0, 0, 0
	switch event.Event {
	case "impression":
		impressions = 1
	case "view":
		views = 1
	case "outbound_click":
		clicks = 1
	}
	_, e = tx.ExecContext(ctx, `INSERT INTO creator_analytics_tracking(author_did,subject_uri,day,impressions,views,outbound_clicks) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(author_did,subject_uri,day) DO UPDATE SET impressions=creator_analytics_tracking.impressions+EXCLUDED.impressions,views=creator_analytics_tracking.views+EXCLUDED.views,outbound_clicks=creator_analytics_tracking.outbound_clicks+EXCLUDED.outbound_clicks`, author, event.SubjectURI, day, impressions, views, clicks)
	if e != nil {
		return e
	}
	return tx.Commit()
}
func (s Store) Summary(ctx context.Context, author string, days, limit int, cursor string, now time.Time) (Summary, error) {
	tx, err := s.DB.BeginTx(ctx, &sql.TxOptions{ReadOnly: true, Isolation: sql.LevelRepeatableRead})
	if err != nil {
		return Summary{}, err
	}
	defer tx.Rollback()
	out := Summary{Items: []Item{}, Series: []Day{}, Coverage: Coverage{TrackingScope: "social-wire", SnapshotSemantics: "cumulative-last-observation-per-day"}}
	since := now.UTC().AddDate(0, 0, -days+1).Format("2006-01-02")
	var complete bool
	var sampledAt time.Time
	e := tx.QueryRowContext(ctx, `SELECT inventory_complete,refreshed_at FROM creator_analytics_refresh WHERE author_did=$1`, author).Scan(&complete, &sampledAt)
	if e != nil && e != sql.ErrNoRows {
		return out, e
	}
	out.Coverage.InventoryComplete = complete
	if !sampledAt.IsZero() {
		out.Coverage.SampledAt = &sampledAt
	}
	out.Coverage.ExcludesSelf = true
	out.Coverage.TrackingRetentionDays = 90
	rows, e := tx.QueryContext(ctx, `SELECT item_json FROM creator_analytics_items WHERE author_did=$1 AND subject_uri>$2 ORDER BY subject_uri LIMIT $3`, author, cursor, limit+1)
	if e != nil {
		return out, e
	}
	for rows.Next() {
		var raw []byte
		if e = rows.Scan(&raw); e != nil {
			rows.Close()
			return out, e
		}
		var it Item
		if e = json.Unmarshal(raw, &it); e != nil {
			rows.Close()
			return out, e
		}
		out.Items = append(out.Items, it)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return out, e
	}
	if len(out.Items) > limit {
		out.Items = out.Items[:limit]
		out.Cursor = out.Items[len(out.Items)-1].URI
	}
	tracking := map[string]Tracking{}
	rows, e = tx.QueryContext(ctx, `SELECT subject_uri,sum(impressions),sum(views),sum(outbound_clicks) FROM creator_analytics_tracking WHERE author_did=$1 AND day >= $2 GROUP BY subject_uri`, author, since)
	if e != nil {
		return out, e
	}
	for rows.Next() {
		var uri string
		var t Tracking
		if e = rows.Scan(&uri, &t.Impressions, &t.Views, &t.OutboundClicks); e != nil {
			rows.Close()
			return out, e
		}
		t.CalculateCTR()
		tracking[uri] = t
		out.Totals.Tracking.Impressions += t.Impressions
		out.Totals.Tracking.Views += t.Views
		out.Totals.Tracking.OutboundClicks += t.OutboundClicks
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return out, e
	}
	out.Totals.Tracking.CalculateCTR()
	for i := range out.Items {
		out.Items[i].Tracking = tracking[out.Items[i].URI]
	}
	rows, e = tx.QueryContext(ctx, `SELECT item_json FROM creator_analytics_items WHERE author_did=$1`, author)
	if e != nil {
		return out, e
	}
	for rows.Next() {
		var raw []byte
		if e = rows.Scan(&raw); e != nil {
			rows.Close()
			return out, e
		}
		var it Item
		if e = json.Unmarshal(raw, &it); e != nil {
			rows.Close()
			return out, e
		}
		out.Coverage.TotalItems++
		if it.Engagement != nil {
			out.Coverage.EngagementKnownItems++
			if out.Totals.Engagement == nil {
				out.Totals.Engagement = &Engagement{}
			}
			g := out.Totals.Engagement
			g.Likes += it.Engagement.Likes
			g.Replies += it.Engagement.Replies
			g.Reposts += it.Engagement.Reposts
			g.Quotes += it.Engagement.Quotes
		}
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return out, e
	}
	var first sql.NullString
	e = tx.QueryRowContext(ctx, `SELECT min(day)::text FROM creator_analytics_snapshots WHERE author_did=$1`, author).Scan(&first)
	if e != nil {
		return out, e
	}
	if first.Valid {
		out.Coverage.SnapshotStart = &first.String
	}
	var trackingFirst sql.NullString
	if e = tx.QueryRowContext(ctx, `SELECT min(day)::text FROM creator_analytics_tracking WHERE author_did=$1`, author).Scan(&trackingFirst); e != nil {
		return out, e
	}
	if trackingFirst.Valid {
		out.Coverage.TrackingStart = &trackingFirst.String
	}
	rows, e = tx.QueryContext(ctx, `WITH days AS (SELECT day FROM creator_analytics_snapshots WHERE author_did=$1 AND day >= $2 UNION SELECT day FROM creator_analytics_tracking WHERE author_did=$1 AND day >= $2), engagement AS (SELECT day,sum(likes) likes,sum(replies) replies,sum(reposts) reposts,sum(quotes) quotes FROM creator_analytics_snapshots WHERE author_did=$1 AND day >= $2 GROUP BY day), tracking AS (SELECT day,sum(impressions) impressions,sum(views) views,sum(outbound_clicks) clicks FROM creator_analytics_tracking WHERE author_did=$1 AND day >= $2 GROUP BY day) SELECT d.day::text,e.likes,e.replies,e.reposts,e.quotes,t.impressions,t.views,t.clicks FROM days d LEFT JOIN engagement e USING(day) LEFT JOIN tracking t USING(day) ORDER BY d.day`, author, since)
	if e != nil {
		return out, e
	}
	for rows.Next() {
		var d Day
		if e = rows.Scan(&d.Day, &d.Likes, &d.Replies, &d.Reposts, &d.Quotes, &d.Impressions, &d.Views, &d.OutboundClicks); e != nil {
			rows.Close()
			return out, e
		}
		if d.Impressions != nil && d.OutboundClicks != nil {
			t := Tracking{Impressions: *d.Impressions, OutboundClicks: *d.OutboundClicks}
			t.CalculateCTR()
			d.CTR = t.CTR
		}
		out.Series = append(out.Series, d)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return out, e
	}
	return out, tx.Commit()
}
