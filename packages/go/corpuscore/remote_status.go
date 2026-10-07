package corpuscore

import "fmt"

// RemoteStatusError distinguishes a valid HTTP refusal from transport or payload failure.
type RemoteStatusError struct{ Status int }

func (e RemoteStatusError) Error() string { return fmt.Sprintf("corpus HTTP status %d", e.Status) }
func (e RemoteStatusError) Unwrap() error {
	if e.Status == 410 {
		return ErrCursorExpired
	}
	return ErrUnavailable
}

// RemoteVersionError identifies a response header mismatch before payload decoding.
type RemoteVersionError struct{}

func (RemoteVersionError) Error() string { return "corpus contract header mismatch" }
func (RemoteVersionError) Unwrap() error { return ErrContractMismatch }
