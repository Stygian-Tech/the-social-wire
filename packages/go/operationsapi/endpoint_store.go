package operationsapi

import (
	"context"
	"time"
)

const endpointColumns = `id,display_name,host,role,connection_state,last_connected_at,last_disconnected_at,last_error,connection_attempts,failover_count,updated_at,version`

func scanEndpoint(row interface{ Scan(...any) error }, env string) (EndpointState, error) {
	endpoint := EndpointState{Environment: env}
	var connected, disconnected *time.Time
	var updated time.Time
	err := row.Scan(&endpoint.ID, &endpoint.DisplayName, &endpoint.Host, &endpoint.Role, &endpoint.ConnectionState, &connected, &disconnected, &endpoint.LastError, &endpoint.ConnectionAttempts, &endpoint.FailoverCount, &updated, &endpoint.Version)
	endpoint.UpdatedAt = WireTime{updated}
	if connected != nil {
		endpoint.LastConnectedAt = &WireTime{*connected}
	}
	if disconnected != nil {
		endpoint.LastDisconnectedAt = &WireTime{*disconnected}
	}
	if endpoint.Role != "active" && endpoint.Role != "standby" {
		endpoint.Role = "standby"
	}
	switch endpoint.ConnectionState {
	case "connected", "disconnected", "reconnecting", "unknown":
	default:
		endpoint.ConnectionState = "unknown"
	}
	return endpoint, err
}
func (s *PostgresStore) ListJetstreamEndpoints(ctx context.Context, limit int, before *string) (Page[EndpointState], error) {
	limit = max(1, min(limit, 250))
	var date *time.Time
	var id *string
	if before != nil {
		cursor, err := DecodePaginationCursor(*before)
		if err != nil {
			return Page[EndpointState]{}, err
		}
		date = &cursor.Date
		id = &cursor.ID
	}
	rows, err := s.DB.Query(ctx, `SELECT `+endpointColumns+` FROM appview_jetstream_endpoints WHERE environment=$1 AND ($2::timestamptz IS NULL OR updated_at<$2::timestamptz OR (updated_at=$2::timestamptz AND id<$3::text)) ORDER BY updated_at DESC,id DESC LIMIT $4`, s.Environment, date, id, limit+1)
	if err != nil {
		return Page[EndpointState]{}, err
	}
	endpoints := []EndpointState{}
	for rows.Next() {
		endpoint, err := scanEndpoint(rows, s.Environment)
		if err != nil {
			rows.Close()
			return Page[EndpointState]{}, err
		}
		endpoints = append(endpoints, endpoint)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return Page[EndpointState]{}, err
	}
	page := Page[EndpointState]{Items: endpoints}
	if err = s.DB.QueryRow(ctx, `SELECT count(*) FROM appview_jetstream_endpoints WHERE environment=$1`, s.Environment).Scan(&page.TotalCount); err != nil {
		return page, err
	}
	if len(endpoints) > limit {
		page.Items = endpoints[:limit]
		last := page.Items[len(page.Items)-1]
		cursor := EncodePaginationCursor(last.UpdatedAt.Time, last.ID)
		page.NextCursor = &cursor
	}
	return page, nil
}
