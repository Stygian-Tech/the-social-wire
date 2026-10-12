package operationsapi

import (
	"context"
	"time"
)

type TabUsageRow struct {
	Tab     string  `json:"tab"`
	DAU     int     `json:"dau"`
	WAU     int     `json:"wau"`
	MAU     int     `json:"mau"`
	Opens   int64   `json:"opens"`
	DwellMS float64 `json:"dwellMs"`
}
type TabUsageSummary struct {
	SourceEnvironment string        `json:"sourceEnvironment"`
	ObservedAt        WireTime      `json:"observedAt"`
	TrackingStart     *WireTime     `json:"trackingStart"`
	DAU               int           `json:"dau"`
	WAU               int           `json:"wau"`
	MAU               int           `json:"mau"`
	Tabs              []TabUsageRow `json:"tabs"`
}

func (s *PostgresStore) FetchTabUsage(ctx context.Context, at time.Time) (*TabUsageSummary, error) {
	budget, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	tx, err := s.DB.Begin(budget)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(context.Background())
	if _, err = tx.Exec(budget, `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY`); err != nil {
		return nil, err
	}
	if _, err = tx.Exec(budget, `SET LOCAL statement_timeout='2s'`); err != nil {
		return nil, err
	}
	environment := s.TabUsageEnvironment
	if environment == "" {
		environment = s.Environment
	}
	result := &TabUsageSummary{SourceEnvironment: environment, ObservedAt: WireTime{at}, Tabs: []TabUsageRow{}}
	var start *time.Time
	err = tx.QueryRow(budget, `SELECT count(DISTINCT viewer_key) FILTER(WHERE activity_day=($2::timestamptz AT TIME ZONE 'UTC')::date),count(DISTINCT viewer_key) FILTER(WHERE activity_day>=($2::timestamptz AT TIME ZONE 'UTC')::date-6),count(DISTINCT viewer_key),(min(activity_day)::timestamp AT TIME ZONE 'UTC') FROM operations_tab_activity WHERE environment=$1 AND activity_day BETWEEN ($2::timestamptz AT TIME ZONE 'UTC')::date-29 AND ($2::timestamptz AT TIME ZONE 'UTC')::date`, environment, at).Scan(&result.DAU, &result.WAU, &result.MAU, &start)
	if err != nil {
		return nil, err
	}
	if start != nil {
		result.TrackingStart = &WireTime{*start}
	}
	rows, err := tx.Query(budget, `SELECT tab,count(DISTINCT viewer_key) FILTER(WHERE activity_day=($2::timestamptz AT TIME ZONE 'UTC')::date),count(DISTINCT viewer_key) FILTER(WHERE activity_day>=($2::timestamptz AT TIME ZONE 'UTC')::date-6),count(DISTINCT viewer_key),sum(opens),sum(dwell_ms) FROM operations_tab_activity WHERE environment=$1 AND activity_day BETWEEN ($2::timestamptz AT TIME ZONE 'UTC')::date-29 AND ($2::timestamptz AT TIME ZONE 'UTC')::date GROUP BY tab ORDER BY sum(opens) DESC,tab`, environment, at)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var row TabUsageRow
		if err = rows.Scan(&row.Tab, &row.DAU, &row.WAU, &row.MAU, &row.Opens, &row.DwellMS); err != nil {
			rows.Close()
			return nil, err
		}
		result.Tabs = append(result.Tabs, row)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(budget); err != nil {
		return nil, err
	}
	return result, nil
}

// Expired pseudonyms are pruned independently of clients or dashboard visits.
func (s *PostgresStore) PruneTabUsage(ctx context.Context, at time.Time) error {
	budget, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	_, err := s.DB.Exec(budget, `DELETE FROM operations_tab_activity WHERE ctid IN(SELECT ctid FROM operations_tab_activity WHERE activity_day<($1::timestamptz AT TIME ZONE 'UTC')::date-29 ORDER BY activity_day LIMIT 10000)`, at)
	return err
}
