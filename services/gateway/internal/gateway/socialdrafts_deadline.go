package gateway

import (
	"context"
	"net/http"
	"time"
)

// Socket deadlines bound blocked HTTP I/O; a request context alone cannot
// interrupt ResponseWriter.Write. Cancellation advances the socket deadline so
// upstream readers and transfer admission are released promptly on disconnect.
func boundSocialDraftIO(ctx context.Context, w http.ResponseWriter, readBody bool) func() {
	controller := http.NewResponseController(w)
	setDeadline := controller.SetWriteDeadline
	if readBody {
		setDeadline = controller.SetReadDeadline
	}
	deadline, _ := ctx.Deadline()
	_ = setDeadline(deadline)
	done := make(chan struct{})
	stop := context.AfterFunc(ctx, func() { defer close(done); _ = setDeadline(time.Now()) })
	return func() {
		if !stop() {
			<-done
		}
		// net/http can drain unread bodies and flush buffered output after ServeHTTP
		// returns. Leave the deadline installed for that work; the server resets it
		// for the next request (or closes this HTTP/2 stream).
	}
}
