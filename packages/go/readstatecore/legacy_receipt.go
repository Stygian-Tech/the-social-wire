package readstatecore

// LegacyReceipt proves the original intent of an action retained during v1-to-v2 migration.
type LegacyReceipt struct {
	ActionID           string `json:"actionId"`
	OriginalSequence   int64  `json:"originalSequence"`
	OriginalIntentHash string `json:"originalIntentHash"`
}

func (receipt LegacyReceipt) Validate() error {
	if receipt.ActionID == "" || len(receipt.ActionID) > 128 || receipt.OriginalSequence < 1 || receipt.OriginalSequence > MaximumSequence || !hashPattern.MatchString(receipt.OriginalIntentHash) {
		return ErrInvalidRecord
	}
	return nil
}
