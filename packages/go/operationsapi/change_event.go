package operationsapi

import "time"

type ChangeEvent struct {
	Environment string            `json:"environment"`
	Cursor      int64             `json:"cursor"`
	EventType   string            `json:"eventType"`
	EntityType  string            `json:"entityType"`
	EntityID    *string           `json:"entityId,omitempty"`
	Payload     map[string]string `json:"payload"`
	OccurredAt  time.Time         `json:"occurredAt"`
}
type ChangeEventCursorBounds struct {
	EarliestAvailable int64 `json:"earliestAvailable"`
	Latest            int64 `json:"latest"`
}

func (b ChangeEventCursorBounds) CanResume(after int64) bool {
	return (after == 0 || after >= b.EarliestAvailable-1) && after <= b.Latest
}
