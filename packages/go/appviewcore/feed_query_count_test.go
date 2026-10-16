package appviewcore

import (
	"context"
	"database/sql/driver"
	"sync/atomic"
)

type feedCountingConnector struct {
	driver.Connector
	calls   *atomic.Int64
	batches *[]int64
}

func (c feedCountingConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return feedCountingConnection{Conn: conn, calls: c.calls, batches: c.batches}, nil
}

type feedCountingConnection struct {
	driver.Conn
	calls   *atomic.Int64
	batches *[]int64
}

func (c feedCountingConnection) QueryContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.calls.Add(1)
	if c.batches != nil {
		*c.batches = append(*c.batches, args[0].Value.(int64))
	}
	return c.Conn.(driver.QueryerContext).QueryContext(ctx, q, args)
}
