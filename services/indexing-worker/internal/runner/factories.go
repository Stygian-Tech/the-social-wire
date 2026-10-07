// Package runner composes the independently supervised workload lanes and the
// public health server. Control capacity never enters a workload factory.
package runner

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/stygian-tech/the-social-wire/packages/go/appviewworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/indexingworkercore"
	"github.com/stygian-tech/the-social-wire/packages/go/operationscore"
	"github.com/stygian-tech/the-social-wire/packages/go/wireworkercore"
	"github.com/stygian-tech/the-social-wire/services/indexing-worker/internal/health"
)

type ownedLane struct {
	indexingworkercore.Lane
	close func() error
	port  int
	role  indexingworkercore.Role
}

// Run retains the workload pool until every child and health request has joined.
func (lane *ownedLane) Run(ctx context.Context, authority *operationscore.RoleLeaseAuthority) (result error) {
	defer func() { result = errors.Join(result, lane.close()) }()
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(lane.port)))
	if err != nil {
		return errors.New("component health listener unavailable")
	}
	return serve(ctx, listener, health.Handler(lane.role, lane.Lane), func(ctx context.Context) error { return lane.Lane.Run(ctx, authority) })
}

func factories(environment map[string]string, config indexingworkercore.Config) map[indexingworkercore.LaneName]indexingworkercore.LaneFactory {
	ranking, graph := &wireworkercore.RankingScheduler{}, &wireworkercore.RankingScheduler{}
	appviewRole, wireRole := domainRoles(config.Role)
	return map[indexingworkercore.LaneName]indexingworkercore.LaneFactory{
		indexingworkercore.AppView: func() (indexingworkercore.Lane, error) {
			host, err := appviewworkercore.NewHost(environment, appviewRole)
			if err != nil {
				return nil, err
			}
			// A missing recovery implementation must not permit coordinator startup.
			if config.Role == indexingworkercore.Coordinator && host.Config.RecoveryEnabled && host.OperationsRecovery == nil {
				_ = host.Close()
				return nil, errors.New("Operations recovery adapter unavailable")
			}
			return &ownedLane{Lane: host, close: host.Close, port: config.AppViewHealthPort, role: config.Role}, nil
		},
		indexingworkercore.Wire: func() (indexingworkercore.Lane, error) {
			host, err := wireworkercore.NewHost(environment, wireRole)
			if err != nil {
				return nil, err
			}
			host.SetSchedulers(ranking, graph)
			return &ownedLane{Lane: host, close: host.DB.Close, port: config.WireHealthPort, role: config.Role}, nil
		},
	}
}
func domainRoles(role indexingworkercore.Role) (appview, wire string) {
	if role == indexingworkercore.Coordinator {
		return "coordinator", "rank"
	}
	return "projection", "drain"
}

// serve joins workload teardown before returning, including when the listener
// fails. A timed-out HTTP shutdown closes connections before pool teardown.
func serve(ctx context.Context, listener net.Listener, handler http.Handler, run func(context.Context) error) error {
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second}
	failures := make(chan error, 2)
	go func() {
		err := server.Serve(listener)
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		failures <- err
	}()
	go func() { failures <- run(child) }()
	var first error
	received := 0
	select {
	case first = <-failures:
		received = 1
	case <-ctx.Done():
		first = ctx.Err()
	}
	cancel()
	shutdown, stop := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	if err := server.Shutdown(shutdown); err != nil {
		_ = server.Close()
	}
	stop()
	for received < 2 {
		err := <-failures
		received++
		if err != nil && !errors.Is(err, context.Canceled) {
			first = errors.Join(first, err)
		}
	}
	return first
}
