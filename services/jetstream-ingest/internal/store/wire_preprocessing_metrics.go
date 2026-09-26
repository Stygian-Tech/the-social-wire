package store

import "sync"

// Input bytes count each enabled StageBatch call once, including failed calls.
// Admission counters count only acknowledged commits. They exclude internal
// transaction retries but intentionally include externally replayed submissions.
type wirePreprocessingSnapshot struct {
	inputBatches, inputEvents, originalBytes, compactBytes          uint64
	committedBatches, acceptedEvents, acceptedBytes, insertedEvents uint64
	filteredPassiveEvents, lookupSubjects, lookupBytes              uint64
}

type wireCommittedMetrics struct {
	acceptedEvents, acceptedBytes, insertedEvents      uint64
	filteredPassiveEvents, lookupSubjects, lookupBytes uint64
}

type wirePreprocessingMetrics struct {
	mu     sync.Mutex
	totals wirePreprocessingSnapshot
}

func (m *wirePreprocessingMetrics) recordInput(events int, originalBytes, compactBytes uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.totals.inputBatches++
	m.totals.inputEvents += uint64(events)
	m.totals.originalBytes += originalBytes
	m.totals.compactBytes += compactBytes
}

func (m *wirePreprocessingMetrics) recordCommitted(batch wireCommittedMetrics) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.totals.committedBatches++
	m.totals.acceptedEvents += batch.acceptedEvents
	m.totals.acceptedBytes += batch.acceptedBytes
	m.totals.insertedEvents += batch.insertedEvents
	m.totals.filteredPassiveEvents += batch.filteredPassiveEvents
	m.totals.lookupSubjects += batch.lookupSubjects
	m.totals.lookupBytes += batch.lookupBytes
}

func (m *wirePreprocessingMetrics) snapshot() wirePreprocessingSnapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.totals
}

// Fixed names only. Values are interval deltas, not payloads, identifiers, or SQL.
// accepted_* measures bytes/events submitted to INSERT after Go admission,
// including replay duplicates; inserted_events is the actual RowsAffected total.
func wirePreprocessingLogValues(enabled bool, current, previous wirePreprocessingSnapshot) []any {
	delta := func(current, previous uint64) uint64 {
		if current < previous {
			return 0
		}
		return current - previous
	}
	return []any{
		"wire_preprocessing_enabled", enabled,
		"wire_input_batches", delta(current.inputBatches, previous.inputBatches),
		"wire_input_events", delta(current.inputEvents, previous.inputEvents),
		"wire_original_payload_bytes", delta(current.originalBytes, previous.originalBytes),
		"wire_compact_payload_bytes", delta(current.compactBytes, previous.compactBytes),
		"wire_committed_batches", delta(current.committedBatches, previous.committedBatches),
		"wire_accepted_submission_events", delta(current.acceptedEvents, previous.acceptedEvents),
		"wire_accepted_submission_payload_bytes", delta(current.acceptedBytes, previous.acceptedBytes),
		"wire_inserted_events", delta(current.insertedEvents, previous.insertedEvents),
		"wire_filtered_passive_events", delta(current.filteredPassiveEvents, previous.filteredPassiveEvents),
		"wire_lookup_subjects", delta(current.lookupSubjects, previous.lookupSubjects),
		"wire_lookup_subject_bytes", delta(current.lookupBytes, previous.lookupBytes),
	}
}
