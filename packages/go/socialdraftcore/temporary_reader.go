package socialdraftcore

import (
	"context"
	"errors"
	"os"
	"sync"
)

// A temporaryReader retains its admission slot until the plaintext file is
// closed and removed. Cancellation reclaims abandoned readers without retaining
// a database connection or creating a goroutine that waits for every download.
type temporaryReader struct {
	file    *os.File
	once    sync.Once
	release func()
	stop    func() bool
	err     error
}

func newTemporaryReader(ctx context.Context, f *os.File, release func()) *temporaryReader {
	r := &temporaryReader{file: f, release: release}
	// The callback deliberately calls cleanup, not Close: it may start before
	// AfterFunc returns its stop function, which Close reads only after construction.
	r.stop = context.AfterFunc(ctx, func() { r.cleanup() })
	return r
}

// Expose only Read/Close. Promoting os.File.WriteTo could retain its descriptor
// across a slow downstream write, delaying cancellation cleanup.
func (r *temporaryReader) Read(p []byte) (int, error) { return r.file.Read(p) }

func (r *temporaryReader) Close() error {
	r.stop()
	return r.cleanup()
}
func (r *temporaryReader) cleanup() error {
	r.once.Do(func() {
		closeErr := r.file.Close()
		removeErr := os.Remove(r.file.Name())
		if os.IsNotExist(removeErr) {
			removeErr = nil
		}
		r.err = errors.Join(closeErr, removeErr)
		if r.release != nil {
			r.release()
		}
	})
	return r.err
}
