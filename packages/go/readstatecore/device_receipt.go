package readstatecore

// Chains contiguous device counters and original-intent hashes with domain separation. A
// remote acknowledgement is accepted only if recomputing the proposed prefix from locally
// pending intents yields the same counter and hash.

import (
	"regexp"
	"strings"
)

var hashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var devicePattern = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

// DeviceReceipt commits a contiguous prefix of one device’s original-intent hashes.
type DeviceReceipt struct {
	DeviceID         string `json:"deviceId"`
	CommittedCounter int64  `json:"committedCounter"`
	PrefixHash       string `json:"prefixHash"`
}

// NewDeviceReceipt creates the viewer/device-bound empty-prefix hash at counter zero.
func NewDeviceReceipt(viewer, device string) (DeviceReceipt, error) {
	if !strings.HasPrefix(viewer, "did:") || len(viewer) > 2048 {
		return DeviceReceipt{}, ErrInvalidRecord
	}
	hash, err := CanonicalHash([]any{"app.thesocialwire.read-state/device/v2", viewer, device})
	if err != nil {
		return DeviceReceipt{}, err
	}
	receipt := DeviceReceipt{device, 0, hash}
	return receipt, receipt.Validate()
}

// Validate rejects values that violate this type’s documented bounds before they are used.
func (receipt DeviceReceipt) Validate() error {
	if !devicePattern.MatchString(receipt.DeviceID) || receipt.CommittedCounter < 0 || receipt.CommittedCounter > MaximumSequence || !hashPattern.MatchString(receipt.PrefixHash) {
		return ErrInvalidRecord
	}
	return nil
}

// Advance returns a new receipt for contiguous intents beginning at committedCounter+1;
// gaps and unsafe counters fail.
func (receipt DeviceReceipt) Advance(first int64, intents []string) (DeviceReceipt, error) {
	if err := receipt.Validate(); err != nil {
		return DeviceReceipt{}, err
	}
	if len(intents) == 0 || first != receipt.CommittedCounter+1 || int64(len(intents)) > MaximumSequence-receipt.CommittedCounter {
		return DeviceReceipt{}, ErrConflictingSequence
	}
	hash := receipt.PrefixHash
	for itemIndex, intent := range intents {
		if !hashPattern.MatchString(intent) {
			return DeviceReceipt{}, ErrInvalidRecord
		}
		var err error
		hash, err = CanonicalHash([]any{"app.thesocialwire.read-state/prefix/v2", hash, first + int64(itemIndex), intent})
		if err != nil {
			return DeviceReceipt{}, err
		}
	}
	return DeviceReceipt{receipt.DeviceID, receipt.CommittedCounter + int64(len(intents)), hash}, nil
}

// VerifiedAcknowledgement returns how many pending intents a remote receipt proves, after
// recomputing and matching its exact prefix.
func (receipt DeviceReceipt) VerifiedAcknowledgement(remote DeviceReceipt, pending []string) (int, error) {
	if err := receipt.Validate(); err != nil {
		return 0, err
	}
	if err := remote.Validate(); err != nil {
		return 0, err
	}
	count := remote.CommittedCounter - receipt.CommittedCounter
	if receipt.DeviceID != remote.DeviceID || count < 0 || count > int64(len(pending)) {
		return 0, ErrConflictingSequence
	}
	expected := receipt
	if count > 0 {
		var err error
		expected, err = receipt.Advance(receipt.CommittedCounter+1, pending[:int(count)])
		if err != nil {
			return 0, err
		}
	}
	if expected != remote {
		return 0, ErrConflictingSequence
	}
	return int(count), nil
}
