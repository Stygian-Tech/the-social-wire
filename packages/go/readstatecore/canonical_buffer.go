package readstatecore

// Stops encoded DAG-CBOR growth at 16 MiB even when the upstream codec writes
// incrementally. This hashing bound is separate from the 64 KiB portable-record JSON
// bound.

import "bytes"

// canonicalBuffer stops the codec from allocating beyond the protocol limit.
type canonicalBuffer struct{ bytes.Buffer }

// Write appends bytes only if the canonical output stays within 16 MiB.
func (buffer *canonicalBuffer) Write(value []byte) (int, error) {
	if len(value) > 16*1024*1024-buffer.Len() {
		return 0, ErrSizeLimit
	}
	return buffer.Buffer.Write(value)
}

// WriteString appends text only if the canonical output stays within 16 MiB.
func (buffer *canonicalBuffer) WriteString(value string) (int, error) {
	if len(value) > 16*1024*1024-buffer.Len() {
		return 0, ErrSizeLimit
	}
	return buffer.Buffer.WriteString(value)
}
