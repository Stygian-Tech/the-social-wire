package runtime

import (
	"context"
	"errors"
	"net"
	"net/http"
	"time"
)

// Run starts background jobs only while the HTTP listener is accepting work.
// It drains handlers before closing auth singleflight, stores, and cache clients.
func (h *Host) Run(ctx context.Context) error {
	listener, err := net.Listen("tcp", h.Config.Address)
	if err != nil {
		return err
	}
	server := &http.Server{Handler: h.Handler, ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 1 << 20, BaseContext: func(net.Listener) context.Context { return h.ctx }}
	if h.Telemetry != nil {
		h.wg.Add(2)
		go func() { defer h.wg.Done(); _ = h.Telemetry.Run(h.ctx) }()
		go func() { defer h.wg.Done(); h.heartbeat(h.ctx) }()
	}
	if h.Redis != nil {
		h.wg.Add(1)
		go func() { defer h.wg.Done(); h.sampleRedis(h.ctx) }()
	}
	done := make(chan error, 1)
	go func() { done <- server.Serve(listener) }()
	select {
	case err = <-done:
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if e := server.Shutdown(shutdown); e != nil {
		_ = server.Close()
		err = errors.Join(err, e)
	}
	closeErr := h.Close(shutdown)
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	return errors.Join(err, closeErr)
}
