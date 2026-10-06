package readstatecore

import "bytes"

// canonicalBuffer stops the codec from allocating beyond the protocol limit.
type canonicalBuffer struct{ bytes.Buffer }

func (b *canonicalBuffer) Write(value []byte) (int, error) {
	if len(value) > 16*1024*1024-b.Len() {
		return 0, ErrSizeLimit
	}
	return b.Buffer.Write(value)
}
func (b *canonicalBuffer) WriteString(value string) (int, error) {
	if len(value) > 16*1024*1024-b.Len() {
		return 0, ErrSizeLimit
	}
	return b.Buffer.WriteString(value)
}
