package operationsapi

type Alert struct {
	ID                     string            `json:"id"`
	Environment            string            `json:"environment"`
	Rule                   string            `json:"rule"`
	ConditionKey           string            `json:"conditionKey"`
	Severity               string            `json:"severity"`
	Status                 string            `json:"status"`
	Summary                string            `json:"summary"`
	Evidence               map[string]string `json:"evidence"`
	RunbookSlug            string            `json:"runbookSlug"`
	OpenedAt               WireTime          `json:"openedAt"`
	UpdatedAt              WireTime          `json:"updatedAt"`
	AcknowledgedByDID      *string           `json:"acknowledgedByDid,omitempty"`
	ResolvedByDID          *string           `json:"resolvedByDid,omitempty"`
	DeliveryAttempts       int               `json:"deliveryAttempts"`
	LastDeliveryError      *string           `json:"lastDeliveryError,omitempty"`
	NextDeliveryAt         *WireTime         `json:"nextDeliveryAt,omitempty"`
	DeliveryDeadLetteredAt *WireTime         `json:"deliveryDeadLetteredAt,omitempty"`
	Version                int               `json:"version"`
}
