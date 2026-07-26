import { Badge } from "@/components/ui/badge"
import type { JetstreamEndpoint } from "@/lib/operations-types"
import { effectiveConnectionState, elapsedSeconds } from "@/lib/observability-values"

function timestamp(value?: string) {
  return value ? new Date(value).toLocaleString() : "—"
}

export function JetstreamEndpointStatus({ endpoints, reference }: { endpoints: JetstreamEndpoint[]; reference: string }) {
  if (endpoints.length === 0) {
    return <p className="border-t p-3 text-xs text-muted-foreground">No endpoint telemetry has been reported yet.</p>
  }
  return (
    <div className="grid border-t md:grid-cols-2">
      {endpoints.map((endpoint) => {
        const fresh = (elapsedSeconds(endpoint.updatedAt, reference) ?? Number.POSITIVE_INFINITY) <= 45
        const effectiveState = effectiveConnectionState({
          connectionState: endpoint.connectionState,
          transportHeartbeatAt: fresh ? endpoint.updatedAt : undefined,
          lastDisconnectedAt: endpoint.lastDisconnectedAt,
          referenceTime: reference,
        })
        const tone =
          effectiveState === "connected"
            ? "success"
            : effectiveState === "unknown"
              ? "neutral"
              : "danger"
        return (
          <article key={endpoint.id} className="grid gap-2 border-b p-3 last:border-b-0 md:border-b-0 md:border-r md:last:border-r-0">
            <div className="flex items-center justify-between gap-3">
              <div className="min-w-0">
                <p className="text-xs font-semibold">{endpoint.displayName}</p>
                <p className="truncate font-mono text-[10px] text-muted-foreground">{endpoint.host}</p>
              </div>
              <div className="flex items-center gap-1.5">
                <Badge tone={endpoint.role === "active" ? "warning" : "neutral"}>{endpoint.role}</Badge>
                <Badge tone={tone}>{effectiveState}</Badge>
              </div>
            </div>
            <dl className="grid grid-cols-2 gap-x-3 gap-y-1 text-[10px]">
              <dt className="text-muted-foreground">Last Connected</dt>
              <dd className="text-right">{timestamp(endpoint.lastConnectedAt)}</dd>
              <dt className="text-muted-foreground">Last Failure</dt>
              <dd className="text-right">{timestamp(endpoint.lastDisconnectedAt)}</dd>
              <dt className="text-muted-foreground">Attempts / Failovers</dt>
              <dd className="text-right font-mono">{endpoint.connectionAttempts} / {endpoint.failoverCount}</dd>
              <dt className="text-muted-foreground">Last Error</dt>
              <dd className="truncate text-right font-mono">{endpoint.lastError ?? "—"}</dd>
              <dt className="text-muted-foreground">Status Evidence</dt>
              <dd className="text-right">{fresh ? "Fresh" : "Expired"}</dd>
            </dl>
          </article>
        )
      })}
    </div>
  )
}
