import { Database } from "lucide-react"
import { DataColumnHeaders } from "@/components/operations/data-column-headers"
import { Badge } from "@/components/ui/badge"
import { Table, TableBody, TableCell, TableHeader, TableRow } from "@/components/ui/table"
import {
  boundedNonNegativeInteger,
  boundedNonNegativeNumber,
  elapsedSeconds,
  serviceHeartbeatIsFresh,
} from "@/lib/observability-values"
import type { Overview, Span } from "@/lib/operations-types"

const formatBytes = (bytes?: number) => {
  const bounded = boundedNonNegativeNumber(bytes)
  if (bounded === null) return "—"
  if (bounded < 1_000_000_000) return `${(bounded / 1_000_000).toFixed(1)} MB`
  return `${(bounded / 1_000_000_000).toFixed(1)} GB`
}
const formatCount = (value?: number) => boundedNonNegativeInteger(value)?.toLocaleString() ?? "—"
const formatRate = (value?: number) => {
  const bounded = boundedNonNegativeNumber(value)
  return bounded === null ? "—" : `${bounded.toLocaleString(undefined, { maximumFractionDigits: 2 })} tx/s`
}
const formatCacheHitRatio = (value?: number) => {
  const bounded = boundedNonNegativeNumber(value)
  return bounded !== null && bounded <= 1 ? `${(bounded * 100).toFixed(1)}%` : "—"
}
const formatObservationTimestamp = (value?: string) => {
  if (!value) return "Unavailable"
  const timestamp = new Date(value)
  return Number.isFinite(timestamp.getTime()) ? timestamp.toLocaleString() : "Unavailable"
}
const isDatabaseSpan = (span: Span) =>
  Boolean(span.attributes.query_name) || span.name.includes(".db.") || span.name.includes("database")

export function DatabaseObservability({ overview, referenceTime = overview.refreshedAt }: { overview: Overview; referenceTime?: string }) {
  const database = overview.database
  const databaseEvidence = overview.evidence.database
  const observationAge = elapsedSeconds(database?.observedAt, referenceTime)
  const evidenceValidUntil = databaseEvidence?.validUntil
    ? new Date(databaseEvidence.validUntil).getTime()
    : Number.NaN
  const databaseFresh =
    observationAge !== null &&
    observationAge <= 60 &&
    databaseEvidence?.accuracy !== "unavailable" &&
    Number.isFinite(evidenceValidUntil) &&
    evidenceValidUntil >= new Date(referenceTime).getTime()
  const spans = overview.recentTraces.filter(isDatabaseSpan)
  const dependencyStates = overview.services.flatMap((service) =>
    serviceHeartbeatIsFresh(service, referenceTime)
      ? [
          service.dependencyState.database,
          service.dependencyState.operations_database,
          service.dependencyState.appview_database,
        ].filter(Boolean)
      : [],
  )
  const databaseReady = dependencyStates.length > 0 && dependencyStates.every((state) => ["healthy", "ready"].includes(state))
  const metrics = [
    {
      label: "Database Availability",
      value: dependencyStates.length ? (databaseReady ? "Ready" : "Degraded") : "Unknown",
      note: `${dependencyStates.length} fresh service dependency reports`,
    },
    { label: "Database Size", value: formatBytes(database?.databaseSizeBytes), note: "Current Postgres database size" },
    ...(database?.connectedBackends !== undefined
      ? [{ label: "Connected Backends", value: formatCount(database.connectedBackends), note: `Configured maximum ${formatCount(database.maxConnections)}` }]
      : []),
    ...(database?.activeQueries !== undefined
      ? [{ label: "Active Queries", value: formatCount(database.activeQueries), note: "Queries active at observation time" }]
      : []),
    ...(database?.transactionRatePerSecond !== undefined
      ? [{ label: "Transaction Rate", value: formatRate(database.transactionRatePerSecond), note: "Delta between consecutive Postgres observations" }]
      : []),
    {
      label: "Postgres Stats Reset",
      value: formatObservationTimestamp(database?.statsResetAt),
      note: "Transaction-rate deltas are valid only within this statistics epoch",
    },
    { label: "Estimated Live Rows", value: formatCount(database?.estimatedRecords), note: "Postgres statistics estimate; not an exact count" },
    { label: "Cache Hit Ratio", value: formatCacheHitRatio(database?.cacheHitRatio), note: "Postgres shared-buffer hit ratio" },
  ]

  return (
    <section className="ops-panel min-w-0 overflow-hidden" aria-label="Database Observability">
      <header className="flex min-h-9 flex-wrap items-center justify-between gap-2 border-b px-3 py-2">
        <div>
          <h2 className="flex items-center gap-2 text-xs font-semibold"><Database className="size-3.5" /> Database Observability</h2>
          <p className="mt-1 text-[9px] text-muted-foreground">
            Observation {database?.observedAt ? new Date(database.observedAt).toLocaleString() : "timestamp unavailable"}
          </p>
        </div>
        <Badge tone={databaseFresh && databaseEvidence?.accuracy === "exact" ? "success" : databaseFresh ? "warning" : "neutral"}>
          {!databaseFresh
            ? observationAge === null
              ? "Evidence Unavailable"
              : `Unknown · expired ${Math.round(observationAge)}s`
            : databaseEvidence?.accuracy ?? "Unclassified Evidence"}
        </Badge>
      </header>
      {!databaseFresh ? (
        <p role="status" className="border-b bg-warning-surface px-3 py-2 text-[10px] text-warning">
          Database observations exceed the 60-second freshness budget. Values below are retained as stale evidence,
          not current state.
        </p>
      ) : null}
      <div className="grid divide-y sm:grid-cols-2 sm:divide-x xl:grid-cols-3">
        {metrics.map((metric) => (
          <div key={metric.label} className="p-3">
            <p className="text-[10px] text-muted-foreground">{metric.label}</p>
            <p className="mt-1 font-mono text-sm font-medium">{metric.value}</p>
            <p className="mt-1 text-[9px] text-muted-foreground">{metric.note}</p>
          </div>
        ))}
      </div>
      {database?.topTables.length ? (
        <div className="border-t">
          <h3 className="px-3 py-2 text-[10px] font-semibold">Largest Tables by Estimated Live Rows</h3>
          <Table>
            <TableHeader><TableRow><DataColumnHeaders labels={["Schema", "Table", "Estimated Live Rows"]} /></TableRow></TableHeader>
            <TableBody>
              {database.topTables.slice(0, 5).map((table) => (
                <TableRow key={`${table.schema}.${table.table}`}>
                  <TableCell>{table.schema}</TableCell>
                  <TableCell className="font-mono">{table.table}</TableCell>
                  <TableCell className="font-mono">~{formatCount(table.estimatedRecords)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      ) : null}
      <div className="border-t">
        <header className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
          <h3 className="text-[10px] font-semibold">Recent Sampled Database Spans</h3>
          <span className="text-[9px] text-muted-foreground">n={spans.length}; no percentile inferred from this sample</span>
        </header>
        {spans.length ? (
          <Table>
            <TableHeader><TableRow><DataColumnHeaders labels={["Time", "Service", "Query", "Duration", "Status", "Trace ID"]} /></TableRow></TableHeader>
            <TableBody>
              {spans.slice(0, 5).map((span) => (
                <TableRow key={span.id}>
                  <TableCell className="font-mono">{new Date(span.startedAt).toLocaleTimeString()}</TableCell>
                  <TableCell>{span.service}</TableCell>
                  <TableCell className="font-mono">{span.attributes.query_name ?? span.name}</TableCell>
                  <TableCell className="font-mono">{span.durationMs.toLocaleString()} ms</TableCell>
                  <TableCell className={span.status === "error" ? "text-destructive" : "ops-success"}>{span.status}</TableCell>
                  <TableCell className="font-mono">{span.traceId.slice(0, 16)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        ) : (
          <p className="p-3 text-[10px] text-muted-foreground">No sampled database spans were reported.</p>
        )}
      </div>
    </section>
  )
}
