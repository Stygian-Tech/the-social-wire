import { OperationsSection } from "@/components/operations/operations-section"
import Link from "next/link"
import { JetstreamEndpointStatus } from "@/components/operations/dashboard/jetstream-endpoint-status"
import { OperatorActionDialog } from "@/components/operations/operator-action-dialog"
import { Badge } from "@/components/ui/badge"
import {
  boundedNonNegativeInteger,
  effectiveConnectionState,
  elapsedSeconds,
} from "@/lib/observability-values"
import { jetstreamStateForOverview } from "@/lib/operations-policy"
import type { EnvironmentName, Overview } from "@/lib/operations-types"

function formatDuration(seconds: number | null) {
  if (seconds === null) return "—"
  const total = Math.floor(seconds)
  const days = Math.floor(total / 86_400)
  const hours = Math.floor((total % 86_400) / 3_600)
  const minutes = Math.floor((total % 3_600) / 60)
  const remainingSeconds = total % 60
  return [days ? `${days}d` : "", hours ? `${hours}h` : "", minutes ? `${minutes}m` : "", `${remainingSeconds}s`]
    .filter(Boolean)
    .join(" ")
}

function formatTimestamp(value?: string) {
  if (!value) return "—"
  const timestamp = new Date(value)
  return Number.isFinite(timestamp.getTime()) ? timestamp.toLocaleString() : "Invalid timestamp"
}

function sourceLabel(source: string) {
  if (source.toLowerCase().includes("jetstream")) return `${source} · unverified supplemental`
  return source
}

export function LiveStream({
  data,
  environment,
  mutationsEnabled = true,
  referenceTime = data.refreshedAt,
}: {
  data: Overview
  environment: EnvironmentName
  mutationsEnabled?: boolean
  referenceTime?: string
}) {
  const state = data.ingestion
  const jetstreamState = jetstreamStateForOverview(data)
  const receivedCursor = boundedNonNegativeInteger(state?.lastReceivedCursor)
  const committedCursor = boundedNonNegativeInteger(state?.lastCommittedCursor)
  const cursorDelta = receivedCursor !== null && committedCursor !== null ? receivedCursor - committedCursor : null
  const connectionState = effectiveConnectionState({
    connectionState: state?.connectionState,
    transportHeartbeatAt: state?.transportHeartbeatAt,
    lastDisconnectedAt: state?.lastDisconnectAt,
    referenceTime,
  })
  const connectionTone =
    connectionState === "connected" ? "success" : connectionState === "unknown" ? "neutral" : "danger"
  const referenceMs = new Date(referenceTime).getTime()
  const queueValidUntilMs = state?.queueEvidence?.validUntil
    ? new Date(state.queueEvidence.validUntil).getTime()
    : Number.NaN
  const queueEvidenceCurrent =
    state?.queueEvidence?.accuracy === "exact" &&
    Number.isFinite(referenceMs) &&
    Number.isFinite(queueValidUntilMs) &&
    queueValidUntilMs >= referenceMs
  const queueEvidenceExpired = state?.queueEvidence?.accuracy === "exact" && !queueEvidenceCurrent
  const metrics = [
    ["Source", state?.source === "jetstream" ? "Jetstream · unverified supplemental" : (state?.source ?? "—")],
    ["Connected Since", formatTimestamp(state?.connectedAt)],
    ["Connection Duration", formatDuration(elapsedSeconds(state?.connectedAt, referenceTime))],
    ["Last Received (μs)", receivedCursor?.toLocaleString() ?? "—"],
    ["Last Committed (μs)", committedCursor?.toLocaleString() ?? "—"],
    ["Cursor Delta", cursorDelta === null ? "—" : cursorDelta < 0 ? "Invalid ordering" : `${cursorDelta.toLocaleString()} μs`],
    ["Last Received Event", formatTimestamp(state?.lastReceivedEventAt)],
    ["Last Committed Event", formatTimestamp(state?.lastCommittedEventAt)],
    ...(queueEvidenceCurrent && state?.queueCapacity !== undefined
      ? [["Processing Queue", `${boundedNonNegativeInteger(state.queueDepth)?.toLocaleString() ?? "—"} / ${boundedNonNegativeInteger(state.queueCapacity)?.toLocaleString() ?? "—"}`]]
      : []),
    ...(queueEvidenceCurrent && state?.queueOverflowTotal !== undefined
      ? [["Queue Overflow", boundedNonNegativeInteger(state.queueOverflowTotal)?.toLocaleString() ?? "—"]]
      : []),
    ["Reconnect Reason", state?.lastDisconnectReason ?? "—"],
  ]
  const reconnect = data.commands?.find((command) => command.action === "reconnect_jetstream")
  const reconnectActive = reconnect?.status === "queued" || reconnect?.status === "running"
  return (
    <OperationsSection
      title={
        <span className="flex items-center gap-2">
          Live Stream / Consumer <Badge tone={connectionTone}>● {connectionState}</Badge>
        </span>
      }
      action={
        reconnectActive ? (
          <Badge tone="warning">Reconnect {reconnect.status}</Badge>
        ) : (
          <OperatorActionDialog
            environment={environment}
            path="/v1/operations/ingestion/reconnect"
            label="Reconnect Jetstream"
            auditNoteRequired={false}
            expectedVersion={jetstreamState?.version}
            disabled={!mutationsEnabled || jetstreamState?.version === undefined}
            disabledReason={!mutationsEnabled ? "Recovery mutations are disabled" : "Stream version evidence is unavailable"}
            targetLabel="ingestion transport"
          />
        )
      }
    >
      <div className="grid grid-cols-2 divide-x divide-y sm:grid-cols-3 xl:grid-cols-5">
        {metrics.map(([label, value]) => (
          <div key={label} className="min-w-0 p-3">
            <p className="text-[9px] text-muted-foreground">{label}</p>
            <p className="mt-1 truncate font-mono text-[10px]">{value}</p>
          </div>
        ))}
      </div>
      <JetstreamEndpointStatus endpoints={data.jetstreamEndpoints ?? []} reference={referenceTime} />
      <nav aria-label="Ingestion drill-downs" className="flex flex-wrap gap-3 border-t px-3 py-2 text-[10px]">
        <Link href="/endpoints" className="ops-touch-link text-primary">View All Endpoints</Link>
        <Link href="/commands" className="ops-touch-link text-primary">View Command History</Link>
      </nav>
      <section className="border-t" aria-labelledby="ingestion-source-status">
        <header className="px-3 py-2">
          <h3 id="ingestion-source-status" className="text-[10px] font-semibold">
            Source-Specific Pipeline Status
          </h3>
          <p className="mt-1 text-[9px] text-muted-foreground">
            Tap, Jetstream, RSS polling, projection repair, and cache maintenance remain independent evidence domains.
          </p>
        </header>
        {data.ingestionSources.length ? (
          <div className="grid gap-px border-t bg-border sm:grid-cols-2 xl:grid-cols-4">
            {data.ingestionSources.map((source) => {
              const sourceState = effectiveConnectionState({
                connectionState: source.connectionState,
                transportHeartbeatAt: source.transportHeartbeatAt,
                lastDisconnectedAt: source.lastDisconnectAt,
                referenceTime,
              })
              return (
                <article key={source.source} className="min-w-0 bg-background p-3">
                  <div className="flex items-start justify-between gap-2">
                    <h4 className="break-all font-mono text-[10px] font-semibold">{sourceLabel(source.source)}</h4>
                    <Badge
                      tone={sourceState === "connected" ? "success" : sourceState === "unknown" ? "neutral" : "danger"}
                    >
                      {sourceState}
                    </Badge>
                  </div>
                  <dl className="mt-3 grid gap-2 text-[9px]">
                    <div>
                      <dt className="text-muted-foreground">Transport Heartbeat</dt>
                      <dd className="mt-0.5 font-mono">{formatTimestamp(source.transportHeartbeatAt)}</dd>
                    </div>
                    <div>
                      <dt className="text-muted-foreground">Last Indexed Mutation</dt>
                      <dd className="mt-0.5 font-mono">{formatTimestamp(source.lastIndexedMutationAt ?? source.lastCommittedAt)}</dd>
                    </div>
                    <div>
                      <dt className="text-muted-foreground">Projection / Validation Watermarks</dt>
                      <dd className="mt-0.5 break-all font-mono">
                        {source.projectionWatermark ?? "—"} / {source.validationWatermark ?? "—"}
                      </dd>
                    </div>
                  </dl>
                </article>
              )
            })}
          </div>
        ) : (
          <p className="border-t p-3 text-[10px] text-muted-foreground">
            Source-specific pipeline evidence is unavailable; no blended status is inferred.
          </p>
        )}
      </section>
      {state && !queueEvidenceCurrent ? (
        <p className="border-t px-3 py-2 text-[10px] text-muted-foreground">
          {queueEvidenceExpired
            ? "Processing queue depth is withheld because its exact evidence has expired."
            : "Processing queue depth is withheld because measured capacity evidence is unavailable."}
        </p>
      ) : null}
      {reconnect ? (
        <p className="border-t px-3 py-2 text-[10px] text-muted-foreground">
          Latest reconnect: <span className="font-medium text-foreground">{reconnect.status}</span>
          {reconnect.failureReason ? ` — ${reconnect.failureReason}` : ""}
        </p>
      ) : null}
    </OperationsSection>
  )
}
