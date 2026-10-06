package readstatecore

import (
	"regexp"
	"strings"
)

var hashPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)
var devicePattern = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

type DeviceReceipt struct {
	DeviceID         string `json:"deviceId"`
	CommittedCounter int64  `json:"committedCounter"`
	PrefixHash       string `json:"prefixHash"`
}

func NewDeviceReceipt(viewer, device string) (DeviceReceipt, error) {
	if !strings.HasPrefix(viewer, "did:") || len(viewer) > 2048 {
		return DeviceReceipt{}, ErrInvalidRecord
	}
	hash, e := CanonicalHash([]any{"app.thesocialwire.read-state/device/v2", viewer, device})
	if e != nil {
		return DeviceReceipt{}, e
	}
	r := DeviceReceipt{device, 0, hash}
	return r, r.Validate()
}
func (r DeviceReceipt) Validate() error {
	if !devicePattern.MatchString(r.DeviceID) || r.CommittedCounter < 0 || r.CommittedCounter > MaximumSequence || !hashPattern.MatchString(r.PrefixHash) {
		return ErrInvalidRecord
	}
	return nil
}
func (r DeviceReceipt) Advance(first int64, intents []string) (DeviceReceipt, error) {
	if err := r.Validate(); err != nil {
		return DeviceReceipt{}, err
	}
	if len(intents) == 0 || first != r.CommittedCounter+1 || int64(len(intents)) > MaximumSequence-r.CommittedCounter {
		return DeviceReceipt{}, ErrConflictingSequence
	}
	hash := r.PrefixHash
	for i, intent := range intents {
		if !hashPattern.MatchString(intent) {
			return DeviceReceipt{}, ErrInvalidRecord
		}
		var e error
		hash, e = CanonicalHash([]any{"app.thesocialwire.read-state/prefix/v2", hash, first + int64(i), intent})
		if e != nil {
			return DeviceReceipt{}, e
		}
	}
	return DeviceReceipt{r.DeviceID, r.CommittedCounter + int64(len(intents)), hash}, nil
}
func (r DeviceReceipt) VerifiedAcknowledgement(remote DeviceReceipt, pending []string) (int, error) {
	if e := r.Validate(); e != nil {
		return 0, e
	}
	if e := remote.Validate(); e != nil {
		return 0, e
	}
	n := remote.CommittedCounter - r.CommittedCounter
	if r.DeviceID != remote.DeviceID || n < 0 || n > int64(len(pending)) {
		return 0, ErrConflictingSequence
	}
	expected := r
	if n > 0 {
		var e error
		expected, e = r.Advance(r.CommittedCounter+1, pending[:int(n)])
		if e != nil {
			return 0, e
		}
	}
	if expected != remote {
		return 0, ErrConflictingSequence
	}
	return int(n), nil
}
