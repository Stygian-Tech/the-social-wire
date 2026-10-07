package topicworkercore

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/financecore"
	"github.com/stygian-tech/the-social-wire/packages/go/sportscore"
)

type swiftDate struct{ time.Time }

func (d *swiftDate) UnmarshalJSON(data []byte) error {
	var number float64
	if json.Unmarshal(data, &number) == nil {
		whole, frac := math.Modf(number)
		d.Time = time.Unix(978307200+int64(whole), int64(frac*1e9)).UTC()
		return nil
	}
	return json.Unmarshal(data, &d.Time)
}
func (d swiftDate) MarshalJSON() ([]byte, error) {
	return json.Marshal(float64(d.Unix()-978307200) + float64(d.Nanosecond())/1e9)
}

type financeSnapshot struct {
	Version     string                   `json:"version"`
	GeneratedAt swiftDate                `json:"generatedAt"`
	Instruments []financecore.Instrument `json:"instruments"`
}
type financeCatalog struct {
	Snapshot              financeSnapshot
	Fingerprint, Revision string
}
type sportsSnapshot struct {
	Version     string              `json:"version"`
	GeneratedAt swiftDate           `json:"generatedAt"`
	Entities    []sportscore.Entity `json:"entities"`
}

func (w *Worker) financeCatalog(ctx context.Context) (*financeCatalog, error) {
	var payload, fingerprint, overrides string
	err := w.DB.QueryRowContext(ctx, `WITH discovered AS MATERIALIZED (SELECT instrument_id,payload FROM finance_instruments WHERE provider_key LIKE 'BBG%' ORDER BY updated_at DESC,instrument_id LIMIT 150) SELECT snapshot.payload::text,(SELECT md5(COALESCE(jsonb_agg(payload ORDER BY instrument_id),'[]'::jsonb)::text) FROM discovered),(SELECT COALESCE(jsonb_agg(payload ORDER BY instrument_id),'[]'::jsonb)::text FROM discovered) FROM finance_catalog_snapshots snapshot WHERE is_active=TRUE LIMIT 1`).Scan(&payload, &fingerprint, &overrides)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var snapshot financeSnapshot
	var discovered []financecore.Instrument
	if err := json.Unmarshal([]byte(payload), &snapshot); err != nil {
		return nil, err
	}
	if err := json.Unmarshal([]byte(overrides), &discovered); err != nil {
		return nil, err
	}
	if len(discovered) > 150 {
		return nil, fmt.Errorf("finance overrides exceed limit")
	}
	byID := map[string]financecore.Instrument{}
	for _, i := range w.policy.Filter(snapshot.Instruments) {
		if _, ok := byID[i.ID]; ok {
			return nil, fmt.Errorf("duplicate finance catalog identity")
		}
		byID[i.ID] = i
	}
	for _, i := range w.policy.Filter(discovered) {
		byID[i.ID] = financecore.ApplyReviewedMetadata(i)
	}
	snapshot.Instruments = []financecore.Instrument{}
	for _, i := range byID {
		snapshot.Instruments = append(snapshot.Instruments, i)
	}
	sort.Slice(snapshot.Instruments, func(i, j int) bool { return snapshot.Instruments[i].ID < snapshot.Instruments[j].ID })
	return &financeCatalog{snapshot, fingerprint, snapshot.Version + ":" + fingerprint + ":" + financecore.ReviewedMetadataVersion + ":" + w.policy.Revision()}, nil
}
func (w *Worker) sportsCatalog(ctx context.Context) (*sportsSnapshot, error) {
	var payload string
	if err := w.DB.QueryRowContext(ctx, `SELECT payload::text FROM sports_catalog_snapshots WHERE is_active=TRUE LIMIT 1`).Scan(&payload); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	var snapshot sportsSnapshot
	if err := json.Unmarshal([]byte(payload), &snapshot); err != nil {
		return nil, err
	}
	return &snapshot, nil
}
