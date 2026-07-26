"use client"

import { useQuery } from "@tanstack/react-query"
import { DataColumnHeaders } from "@/components/operations/data-column-headers"
import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import { Table, TableBody, TableCell, TableHeader, TableRow } from "@/components/ui/table"
import { useOperationsAuth } from "@/lib/auth-context"
import { fetchTraceSpans } from "@/lib/operations-api"

export function TraceDetail({ traceId }: { traceId?: string }) {
  const { session } = useOperationsAuth()
  const trace = useQuery({
    queryKey: ["operations-trace", traceId],
    queryFn: () => fetchTraceSpans(session, traceId!),
    enabled: Boolean(traceId),
  })

  if (!traceId) return <p className="text-xs text-muted-foreground">Select a sampled span to inspect its trace.</p>
  if (trace.isLoading) return <p className="text-xs text-muted-foreground">Loading recorded trace spans…</p>
  if (trace.error)
    return (
      <p role="alert" className="text-xs text-destructive">
        {trace.error.message}
      </p>
    )

  const spans = trace.data?.traces ?? []
  if (spans.length === 0)
    return <p className="text-xs text-muted-foreground">No recorded spans were found for trace {traceId}.</p>

  return (
    <div className="grid min-w-0 grid-cols-[minmax(0,1fr)] gap-3">
      <OperationsSection title={<span className="font-mono">Trace {traceId} · Recorded Spans ({spans.length})</span>}>
        <div className="grid gap-2 p-3 md:hidden">
          {spans.map((span) => (
            <article key={span.id} className="rounded-md border bg-background p-3">
              <header className="flex items-start justify-between gap-3">
                <h3 className="break-all font-mono text-xs font-semibold">{span.name}</h3>
                <Badge tone={span.status === "error" ? "danger" : "success"}>{span.status}</Badge>
              </header>
              <dl className="mt-3 grid grid-cols-2 gap-2 text-[10px]">
                <div><dt className="text-muted-foreground">Service</dt><dd className="mt-0.5">{span.service}</dd></div>
                <div><dt className="text-muted-foreground">Duration</dt><dd className="mt-0.5 font-mono">{span.durationMs.toLocaleString()} ms</dd></div>
                <div><dt className="text-muted-foreground">Observed</dt><dd className="mt-0.5">{new Date(span.startedAt).toLocaleString()}</dd></div>
                <div><dt className="text-muted-foreground">Parent Span</dt><dd className="mt-0.5 break-all font-mono">{span.parentSpanId ?? "—"}</dd></div>
                <div className="col-span-2"><dt className="text-muted-foreground">Span ID</dt><dd className="mt-0.5 break-all font-mono">{span.id}</dd></div>
              </dl>
            </article>
          ))}
        </div>
        <div className="hidden md:block">
          <Table>
            <TableHeader>
              <TableRow>
                <DataColumnHeaders
                  labels={["Time", "Span ID", "Parent Span", "Service", "Operation", "Duration", "Status"]}
                />
              </TableRow>
            </TableHeader>
            <TableBody>
              {spans.map((span) => (
                <TableRow key={span.id}>
                  <TableCell className="font-mono">{new Date(span.startedAt).toLocaleTimeString()}</TableCell>
                  <TableCell className="font-mono">{span.id}</TableCell>
                  <TableCell className="font-mono">{span.parentSpanId ?? "—"}</TableCell>
                  <TableCell>{span.service}</TableCell>
                  <TableCell className="font-mono">{span.name}</TableCell>
                  <TableCell className="font-mono">{span.durationMs.toLocaleString()} ms</TableCell>
                  <TableCell className={span.status === "error" ? "text-destructive" : "ops-success"}>
                    {span.status}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      </OperationsSection>
      <OperationsSection title="Recorded Span Attributes">
        <div className="divide-y">
          {spans.map((span) => (
            <section key={span.id} className="p-3">
              <h3 className="font-mono text-[10px] font-semibold">{span.id}</h3>
              {Object.keys(span.attributes).length ? (
                <dl className="mt-2 grid gap-px overflow-hidden rounded-md border bg-border text-[10px] sm:grid-cols-2">
                  {Object.entries(span.attributes).map(([key, value]) => (
                    <div key={key} className="grid grid-cols-[minmax(0,1fr)_minmax(0,1.5fr)] gap-2 bg-background p-2">
                      <dt className="break-all font-mono text-muted-foreground">{key}</dt>
                      <dd className="break-all font-mono">{value}</dd>
                    </div>
                  ))}
                </dl>
              ) : (
                <p className="mt-1 text-[10px] text-muted-foreground">No attributes were recorded for this span.</p>
              )}
            </section>
          ))}
        </div>
      </OperationsSection>
    </div>
  )
}
