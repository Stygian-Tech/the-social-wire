package operationsapi

import (
	"sync"
	"time"
)

type DatabaseTableRecordCount struct {
	Schema           string `json:"schema"`
	Table            string `json:"table"`
	EstimatedRecords int64  `json:"estimatedRecords"`
}
type DatabaseObservabilitySnapshot struct {
	DatabaseSizeBytes        int64                      `json:"databaseSizeBytes"`
	ActiveConnections        int64                      `json:"activeConnections"`
	MaxConnections           int64                      `json:"maxConnections"`
	TransactionsTotal        int64                      `json:"transactionsTotal"`
	EstimatedRecords         int64                      `json:"estimatedRecords"`
	CacheHitRatio            *float64                   `json:"cacheHitRatio,omitempty"`
	StatsResetAt             *WireTime                  `json:"statsResetAt,omitempty"`
	TopTables                []DatabaseTableRecordCount `json:"topTables"`
	ConnectedBackends        int64                      `json:"connectedBackends"`
	ActiveQueries            int64                      `json:"activeQueries"`
	TransactionRatePerSecond *float64                   `json:"transactionRatePerSecond,omitempty"`
	ObservedAt               WireTime                   `json:"observedAt"`
	EvidenceAgeSeconds       float64                    `json:"evidenceAgeSeconds"`
}
type databaseCounterSample struct {
	connections, maxConnections, transactions, activeQueries int64
	cacheHitRatio                                            *float64
	statsResetAt                                             *time.Time
	at                                                       time.Time
}
type databaseTableSample struct {
	size, records int64
	topTables     []DatabaseTableRecordCount
	at            time.Time
}
type DatabaseObservations struct {
	mu                 sync.Mutex
	counters           *databaseCounterSample
	tables             *databaseTableSample
	transactionRate    *float64
	running            map[string]bool
	last               map[string]time.Time
	walBytes, walReset float64
	walAt              time.Time
	nextExpiry         int
}

func (d *DatabaseObservations) RecordCounters(sample databaseCounterSample) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.transactionRate = nil
	if previous := d.counters; previous != nil && sample.at.After(previous.at) && equalTime(sample.statsResetAt, previous.statsResetAt) && sample.transactions >= previous.transactions {
		rate := float64(sample.transactions-previous.transactions) / sample.at.Sub(previous.at).Seconds()
		d.transactionRate = &rate
	}
	d.counters = &sample
}
func equalTime(a, b *time.Time) bool {
	return a == nil && b == nil || a != nil && b != nil && a.Equal(*b)
}
func (d *DatabaseObservations) RecordTables(sample databaseTableSample) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.tables = &sample
}
func (d *DatabaseObservations) Snapshot(at time.Time) *DatabaseObservabilitySnapshot {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.counters == nil || d.tables == nil {
		return nil
	}
	c, t := d.counters, d.tables
	observed := c.at
	if t.at.Before(observed) {
		observed = t.at
	}
	snapshot := &DatabaseObservabilitySnapshot{DatabaseSizeBytes: t.size, ActiveConnections: c.connections, MaxConnections: c.maxConnections, TransactionsTotal: c.transactions, EstimatedRecords: t.records, TopTables: append([]DatabaseTableRecordCount{}, t.topTables...), ConnectedBackends: c.connections, ActiveQueries: c.activeQueries, ObservedAt: WireTime{observed}, EvidenceAgeSeconds: max(0, at.Sub(observed).Seconds())}
	if c.cacheHitRatio != nil {
		snapshot.CacheHitRatio = pointer(*c.cacheHitRatio)
	}
	if c.statsResetAt != nil {
		snapshot.StatsResetAt = &WireTime{*c.statsResetAt}
	}
	if d.transactionRate != nil {
		snapshot.TransactionRatePerSecond = pointer(*d.transactionRate)
	}
	return snapshot
}
