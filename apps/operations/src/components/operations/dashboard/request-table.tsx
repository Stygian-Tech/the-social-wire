import { ExternalLink } from "lucide-react"
import Link from "next/link"
import { DataColumnHeaders } from "@/components/operations/data-column-headers"
import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import { Table, TableBody, TableCell, TableHeader, TableRow } from "@/components/ui/table"
import type { Span } from "@/lib/operations-types"

function visibleSpans(spans: Span[], refreshedAt?: string) {
  if (!refreshedAt) return spans
  const end = new Date(refreshedAt).getTime()
  if (!Number.isFinite(end)) return []
  const start = end - 15 * 60_000
  return spans.filter((span) => {
    const timestamp = new Date(span.startedAt).getTime()
    return Number.isFinite(timestamp) && timestamp >= start && timestamp <= end
  })
}

function SpanCard({ span }: { span: Span }) {
  return (
    <article className="rounded-md border bg-background p-3">
      <header className="flex items-start justify-between gap-3">
        <h3 className="break-all font-mono text-xs font-semibold">{span.attributes.route_template ?? span.name}</h3>
        <Badge tone={span.status === "error" ? "danger" : "success"}>{span.status}</Badge>
      </header>
      <dl className="mt-3 grid grid-cols-2 gap-2 text-[10px]">
        <div><dt className="text-muted-foreground">Service</dt><dd className="mt-0.5">{span.service}</dd></div>
        <div><dt className="text-muted-foreground">Duration</dt><dd className="mt-0.5 font-mono">{span.durationMs.toLocaleString()} ms</dd></div>
        <div><dt className="text-muted-foreground">Observed</dt><dd className="mt-0.5">{new Date(span.startedAt).toLocaleString()}</dd></div>
        <div><dt className="text-muted-foreground">Method / Class</dt><dd className="mt-0.5 font-mono">{span.attributes.method ?? "—"} · {span.attributes.status_class ?? "—"}</dd></div>
        <div className="col-span-2"><dt className="text-muted-foreground">Trace</dt><dd className="mt-0.5 break-all font-mono">{span.traceId}</dd></div>
      </dl>
      <Link href={`/traces/${span.traceId}`} className="ops-touch-link mt-3 text-[10px] text-primary">
        View Trace <ExternalLink className="inline size-3" />
      </Link>
    </article>
  )
}

export function RequestTable({ spans, refreshedAt, expanded = false }: { spans: Span[]; refreshedAt?: string; expanded?: boolean }) {
  const observed = visibleSpans(spans, refreshedAt)
  return (
    <OperationsSection
      title="Sampled Request Spans"
      description="Samples whose observed timestamp falls inside the displayed 15-minute window; not request volume."
      action={
        expanded ? undefined : (
          <Link href="/appview" className="ops-touch-link text-[10px] text-primary">View Sampled Spans <ExternalLink className="inline size-3" /></Link>
        )
      }
    >
      {observed.length === 0 ? (
        <p className="p-6 text-center text-xs text-muted-foreground">No sampled spans were observed in this exact window.</p>
      ) : (
        <>
          <div className="grid gap-2 p-3 md:hidden">{observed.slice(0, expanded ? undefined : 5).map((span) => <SpanCard key={span.id} span={span} />)}</div>
          <div className="hidden md:block">
            <Table>
              <TableHeader><TableRow><DataColumnHeaders labels={["Time", "Span ID", "Trace ID", "Service", "Normalized Operation", "Method", "Span Status", "HTTP Class", "Latency", "Error Type", "Environment", "Trace"]} /></TableRow></TableHeader>
              <TableBody>
                {observed.slice(0, expanded ? undefined : 5).map((span) => (
                  <TableRow key={span.id}>
                    <TableCell className="font-mono">{new Date(span.startedAt).toLocaleTimeString()}</TableCell>
                    <TableCell className="font-mono">{span.id}</TableCell>
                    <TableCell className="font-mono">{span.traceId.slice(0, 16)}</TableCell>
                    <TableCell>{span.service}</TableCell>
                    <TableCell className="max-w-64 truncate font-mono">{span.attributes.route_template ?? span.name}</TableCell>
                    <TableCell className="font-mono">{span.attributes.method ?? "—"}</TableCell>
                    <TableCell><Badge tone={span.status === "error" ? "danger" : "success"}>{span.status}</Badge></TableCell>
                    <TableCell className="font-mono">{span.attributes.status_class ?? "—"}</TableCell>
                    <TableCell className="font-mono">{span.durationMs.toLocaleString()} ms</TableCell>
                    <TableCell className="font-mono">{span.attributes.error_type ?? "—"}</TableCell>
                    <TableCell>{span.attributes.environment ?? "—"}</TableCell>
                    <TableCell><Link href={`/traces/${span.traceId}`} aria-label={`View trace ${span.traceId}`} className="ops-touch-link text-primary">View <ExternalLink className="inline size-3" /></Link></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </>
      )}
    </OperationsSection>
  )
}
