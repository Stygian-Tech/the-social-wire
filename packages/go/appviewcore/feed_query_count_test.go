package appviewcore

import (
	"context"
	"database/sql/driver"
	"sync/atomic"
)

type feedCountingConnector struct {
	driver.Connector
	calls        *atomic.Int64
	batches      *[]int64
	metadataRows *atomic.Int64
}

func (c feedCountingConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.Connector.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return feedCountingConnection{Conn: conn, calls: c.calls, batches: c.batches, metadataRows: c.metadataRows}, nil
}

type feedCountingConnection struct {
	driver.Conn
	calls        *atomic.Int64
	batches      *[]int64
	metadataRows *atomic.Int64
}

func (c feedCountingConnection) QueryContext(ctx context.Context, q string, args []driver.NamedValue) (driver.Rows, error) {
	c.calls.Add(1)
	if c.batches != nil {
		*c.batches = append(*c.batches, args[0].Value.(int64))
	}
	rows, err := c.Conn.(driver.QueryerContext).QueryContext(ctx, q, args)
	if err == nil && c.metadataRows != nil && (q == feedChunkFirstQuery || q == feedChunkCursorQuery) {
		return feedCountingRows{Rows: rows, count: c.metadataRows}, nil
	}
	return rows, err
}

type feedCountingRows struct {
	driver.Rows
	count *atomic.Int64
}

func (r feedCountingRows) Next(values []driver.Value) error {
	err := r.Rows.Next(values)
	if err == nil {
		r.count.Add(1)
	}
	return err
}
