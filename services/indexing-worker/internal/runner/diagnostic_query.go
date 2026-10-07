package runner

// Mirrors the reference failure-only snapshot without reading query text.
const diagnosticQuery = `WITH activity AS MATERIALIZED (
          SELECT pid, state, wait_event_type, wait_event, application_name, query_id,
            CASE WHEN xact_start IS NOT NULL THEN
              GREATEST(0, EXTRACT(EPOCH FROM (statement_timestamp() - xact_start)) * 1000)
            END AS transaction_age_ms,
            CASE WHEN state = 'active' AND query_start IS NOT NULL THEN
              GREATEST(0, EXTRACT(EPOCH FROM (statement_timestamp() - query_start)) * 1000)
            END AS query_age_ms
          FROM pg_stat_activity
          WHERE datname = current_database() AND backend_type = 'client backend'
            AND pid <> pg_backend_pid()
        ), sampled AS MATERIALIZED (
          SELECT pid, wait_event_type, wait_event, application_name, query_id,
            transaction_age_ms, query_age_ms, pg_blocking_pids(pid) AS blockers
          FROM activity WHERE wait_event_type IS NOT NULL OR state = 'active'
          ORDER BY (wait_event_type = 'Lock') DESC NULLS LAST, (state = 'active') DESC, pid LIMIT 16
        ), lease AS (
          SELECT owner_id, fencing_token, lease_expires_at FROM operations_role_leases
          WHERE environment = $1 AND role = $2
        )
        SELECT clock_timestamp(), lease.owner_id, lease.fencing_token, lease.lease_expires_at,
          (SELECT COUNT(*)::bigint FROM activity),
          (SELECT COUNT(*)::bigint FROM activity WHERE state = 'active'),
          (SELECT COUNT(*)::bigint FROM activity WHERE state = 'idle'),
          (SELECT COUNT(*)::bigint FROM activity WHERE wait_event_type IS NOT NULL),
          COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'pid', pid, 'waitEventType', wait_event_type, 'waitEvent', wait_event,
            'applicationName', application_name, 'queryID', query_id::text,
            'transactionAgeMilliseconds', transaction_age_ms, 'queryAgeMilliseconds', query_age_ms,
            'blockingPIDs', blockers[1:16], 'blockersTruncated', cardinality(blockers) > 16
          )) FROM sampled), '[]'::jsonb)::text,
          (SELECT COUNT(*)::bigint FROM activity WHERE wait_event_type IS NOT NULL OR state = 'active')
        FROM (SELECT 1) AS present LEFT JOIN lease ON TRUE`
