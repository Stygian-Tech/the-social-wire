package socialdrafts

import (
	"context"
	"net/http"
	"time"
)

const transferTimeout = 2 * time.Minute
const mutationTimeout = 60 * time.Second

// Direct authenticated AppView clients need the same bounded socket I/O as
// Gateway clients. Cancellation must interrupt blocked writes/reads, not merely
// cancel storage work, so deferred reader Close can release its admission slot.
func boundTransferIO(ctx context.Context, w http.ResponseWriter, readBody bool) func() {
	controller := http.NewResponseController(w)
	setDeadline := func(at time.Time) {
		_ = controller.SetWriteDeadline(at)
		if readBody {
			_ = controller.SetReadDeadline(at)
		}
	}
	deadline, _ := ctx.Deadline()
	setDeadline(deadline)
	done := make(chan struct{})
	stop := context.AfterFunc(ctx, func() { defer close(done); setDeadline(time.Now()) })
	return func() {
		if !stop() {
			<-done
		}
		// net/http can drain unread bodies and flush buffered output after ServeHTTP
		// returns. Leave the deadline installed for that work; the server resets it
		// for the next request (or closes this HTTP/2 stream).
	}
}
