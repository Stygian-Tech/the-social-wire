import type { OAuthSession } from "@/lib/auth"
import { authFetch } from "@/lib/auth"
import { operationsEnvironment } from "@/lib/app-environment"
import { demoGapInvestigation, demoMetricRollups, demoOverview } from "@/lib/demo-data"
import type {
  AlertListResponse,
  AppViewOperationsResponse,
  Backfill,
  BackfillDryRun,
  BackfillListResponse,
  CommandListResponse,
  DryRunResult,
  EndpointListResponse,
  GapListResponse,
  GapInvestigation,
  IngestionResponse,
  MetricListResponse,
  Overview,
  ServiceListResponse,
  TraceListResponse,
} from "@/lib/operations-types"

export function gatewayOrigin() {
  return (
    process.env.NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN ||
    (operationsEnvironment() === "prod"
      ? "https://api.thesocialwire.app"
      : "https://api.testing.thesocialwire.app")
  )
}
const requestId = () => crypto.randomUUID()
const randomHex = (bytes: number) =>
  Array.from(crypto.getRandomValues(new Uint8Array(bytes)), (value) => value.toString(16).padStart(2, "0")).join("")
const traceparent = () => `00-${randomHex(16)}-${randomHex(8)}-01`
const demoEvidence = (source: string) => ({
  source,
  accuracy: "estimated" as const,
  generatedAt: new Date().toISOString(),
  ageSeconds: 0,
  validUntil: new Date(Date.now() + 75_000).toISOString(),
  coverage: 1,
  lastSuccessfulAt: new Date().toISOString(),
  degradedReason: "Demo values are illustrative and do not describe a deployed service.",
})
export async function operationsRequest<T>(session: OAuthSession | null, path: string, init?: RequestInit): Promise<T> {
  if (process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE === "1") {
    if ((init?.method ?? "GET").toUpperCase() !== "GET") throw new DemoReadOnlyError()
    await new Promise((resolve) => setTimeout(resolve, 80))
    if (path === "/v1/operations/overview")
      return {
        ...demoOverview,
        metricRollups: demoMetricRollups(),
        refreshedAt: new Date().toISOString(),
        evidence: {
          ...demoOverview.evidence,
          overview: {
            ...demoOverview.evidence?.overview,
            source: "Synthetic demo fixture",
            accuracy: "estimated",
            generatedAt: new Date().toISOString(),
            ageSeconds: 0,
            validUntil: new Date(Date.now() + 75_000).toISOString(),
          },
        },
      } as T
    if (/^\/v1\/operations\/gaps\/[^/]+\/investigation$/.test(path))
      return demoGapInvestigation(path.split("/")[4]!) as T
    if (/^\/v1\/operations\/traces\/[^/]+$/.test(path)) {
      const traceId = decodeURIComponent(path.split("/")[4]!)
      const traces = demoOverview.recentTraces.filter((span) => span.traceId === traceId)
      return {
        traces,
        totalCount: traces.length,
        truncated: false,
        evidence: demoEvidence("Synthetic trace fixture"),
      } as T
    }
    if (path.startsWith("/v1/operations/traces?"))
      return {
        traces: demoOverview.recentTraces,
        totalCount: demoOverview.recentTraces.length,
        truncated: false,
        evidence: demoEvidence("Synthetic trace fixture"),
      } as T
    if (path.startsWith("/v1/operations/metrics?"))
      return {
        rollups: demoMetricRollups(),
        evidence: {
          source: "Synthetic demo fixture",
          accuracy: "estimated",
          generatedAt: new Date().toISOString(),
          ageSeconds: 0,
          validUntil: new Date(Date.now() + 75_000).toISOString(),
          coverage: 1,
          degradedReason: "Demo values are illustrative and do not describe a deployed service.",
        },
      } as T
    if (path.startsWith("/v1/operations/gaps?") || path === "/v1/operations/gaps") {
      const view = new URL(path, "https://demo.invalid").searchParams.get("view") ?? "active"
      const gaps = demoOverview.gaps!.filter((gap) =>
        view === "history" ? ["resolved", "ignored"].includes(gap.status) : !["resolved", "ignored"].includes(gap.status),
      )
      return { gaps, totalCount: gaps.length, evidence: demoEvidence("Synthetic gap fixture") } as T
    }
    if (path.startsWith("/v1/operations/backfills?") || path === "/v1/operations/backfills") {
      const view = new URL(path, "https://demo.invalid").searchParams.get("view") ?? "active"
      const statuses =
        view === "history"
          ? new Set(["completed"])
          : view === "needs_attention"
            ? new Set(["failed", "cancelled"])
            : new Set(["queued", "running", "paused"])
      const backfills = demoOverview.backfills!.filter((job) => statuses.has(job.status))
      return {
        backfills,
        totalCount: backfills.length,
        evidence: demoEvidence("Synthetic backfill fixture"),
      } as T
    }
    if (path.startsWith("/v1/operations/alerts?") || path === "/v1/operations/alerts") {
      const view = new URL(path, "https://demo.invalid").searchParams.get("view") ?? "active"
      const alerts = demoOverview.alerts!.filter((alert) =>
        view === "history" ? alert.status === "resolved" : alert.status !== "resolved",
      )
      return { alerts, totalCount: alerts.length, evidence: demoEvidence("Synthetic alert fixture") } as T
    }
    if (path.startsWith("/v1/operations/commands?") || path === "/v1/operations/commands")
      return {
        commands: demoOverview.commands,
        totalCount: demoOverview.commands.length,
        evidence: demoEvidence("Synthetic command fixture"),
      } as T
    if (path.startsWith("/v1/operations/ingestion/endpoints?") || path === "/v1/operations/ingestion/endpoints")
      return {
        endpoints: demoOverview.jetstreamEndpoints,
        totalCount: demoOverview.jetstreamEndpoints.length,
        evidence: demoEvidence("Synthetic endpoint fixture"),
      } as T
    if (path === "/v1/operations/services")
      return {
        services: demoOverview.services,
        evidence: demoEvidence("Synthetic service heartbeat fixture"),
      } as T
    if (path === "/v1/operations/ingestion")
      return {
        state: demoOverview.ingestion,
        sources: demoOverview.ingestionSources,
        evidence: demoEvidence("Synthetic ingestion fixture"),
      } as T
    if (path === "/v1/operations/appview")
      return {
        services: demoOverview.services.filter(({ service }) => service === "appview" || service === "gateway"),
        evidence: demoEvidence("Synthetic AppView heartbeat fixture"),
      } as T
    if (/^\/v1\/operations\/backfills\/[^/]+$/.test(path)) {
      const id = decodeURIComponent(path.split("/")[4]!)
      const job = demoOverview.backfills!.find((candidate) => candidate.id === id)
      if (job) return job as T
      throw new Error("Backfill not found")
    }
    return demoOverview as T
  }
  if (!session) throw new Error("Operator authentication is required")
  const headers = new Headers(init?.headers)
  headers.set("Accept", "application/json")
  headers.set("X-Request-ID", requestId())
  headers.set("traceparent", traceparent())
  if (init?.body) headers.set("Content-Type", "application/json")
  const response = await authFetch(session, `${gatewayOrigin()}${path}`, { ...init, headers })
  if (response.status === 403) throw new OperationsForbiddenError()
  if (!response.ok) {
    const payload = await response.json().catch(() => undefined) as { message?: string; error?: string } | undefined
    throw new OperationsHttpError(
      response.status,
      payload?.message ?? payload?.error ?? `Operations request failed (${response.status})`,
      response.headers.get("Retry-After") ?? undefined,
    )
  }
  const expectedStatus = expectedOperationsSuccessStatus(path, init?.method)
  if (response.status !== expectedStatus)
    throw new Error(
      `Operations response returned ${response.status}; contract requires ${expectedStatus}`,
    )
  const payload = await response.json() as unknown
  if (path === "/v1/operations/overview") assertOverviewResponse(payload)
  if (
    path === "/v1/operations/backfills" &&
    (init?.method ?? "GET").toUpperCase() === "POST"
  )
    assertBackfill(payload, operationsEnvironment())
  if (
    /^\/v1\/operations\/backfills\/[^/?]+$/.test(path) &&
    path !== "/v1/operations/backfills/dry-run"
  )
    assertBackfill(payload, operationsEnvironment())
  if (/^\/v1\/operations\/backfills\/[^/?]+\/(pause|resume|cancel)$/.test(path))
    assertBackfill(payload, operationsEnvironment())
  if (/^\/v1\/operations\/alerts\/[^/?]+\/(acknowledge|resolve|retry)$/.test(path))
    assertAlert(payload, operationsEnvironment())
  if (path === "/v1/operations/ingestion/reconnect")
    assertCommand(payload, operationsEnvironment())
  if (/^\/v1\/operations\/gaps\/[^/?]+\/investigation$/.test(path))
    assertGapInvestigation(payload, operationsEnvironment())
  return payload as T
}
export const fetchOverview = (session: OAuthSession | null) =>
  operationsRequest<Overview>(session, "/v1/operations/overview")
export const fetchServices = async (session: OAuthSession | null) => {
  const response = await operationsRequest<ServiceListResponse>(session, "/v1/operations/services")
  assertServiceResponse(response)
  return response
}
export const fetchIngestion = async (session: OAuthSession | null) => {
  const response = await operationsRequest<IngestionResponse>(session, "/v1/operations/ingestion")
  assertIngestionResponse(response)
  return response
}
export const fetchAppViewOperations = async (session: OAuthSession | null) => {
  const response = await operationsRequest<AppViewOperationsResponse>(session, "/v1/operations/appview")
  assertServiceResponse(response)
  return response
}
export const fetchBackfill = (session: OAuthSession | null, backfillId: string) =>
  operationsRequest<Backfill>(session, `/v1/operations/backfills/${encodeURIComponent(backfillId)}`)
export const fetchGapInvestigation = (session: OAuthSession | null, gapId: string) =>
  operationsRequest<GapInvestigation>(session, `/v1/operations/gaps/${encodeURIComponent(gapId)}/investigation`)
export const fetchTraceSpans = (session: OAuthSession | null, traceId: string) =>
  validatedTracePage(
    operationsRequest<TraceListResponse>(session, `/v1/operations/traces/${encodeURIComponent(traceId)}`),
  )
export const fetchRecentTraces = (session: OAuthSession | null, before?: string) => {
  return validatedTracePage(
    operationsRequest<TraceListResponse>(session, listPath("/v1/operations/traces", { before })),
  )
}
export async function fetchMetrics(session: OAuthSession | null, reference = new Date()) {
  const closedThrough = new Date(Math.floor(reference.getTime() / 60_000) * 60_000)
  const from = new Date(closedThrough.getTime() - 15 * 60_000)
  const parameters = new URLSearchParams({
    from: from.toISOString(),
    to: closedThrough.toISOString(),
    resolution: "1m",
  })
  const response = await operationsRequest<MetricListResponse>(
    session,
    `/v1/operations/metrics?${parameters}`,
  )
  if (!isRecord(response) || !Array.isArray(response.rollups))
    throw new Error("Operations metrics response failed runtime contract validation")
  assertEvidence(response.evidence)
  response.rollups.forEach((item) => assertMetric(item, operationsEnvironment()))
  return response
}
export const dryRunBackfill = async (session: OAuthSession | null, request: BackfillDryRun) => {
  const response = await operationsRequest<DryRunResult>(session, "/v1/operations/backfills/dry-run", {
    method: "POST",
    body: JSON.stringify(request),
  })
  assertDryRun(response)
  return response
}
export type GapListView = "active" | "history" | "all"
export type BackfillListView = "active" | "needs_attention" | "history" | "all"
export type AlertListView = "active" | "history" | "all"

export const fetchGaps = async (session: OAuthSession | null, view: GapListView = "active", before?: string) => {
  const response = await operationsRequest<GapListResponse>(
    session,
    listPath("/v1/operations/gaps", { view, before }),
  )
  assertListResponse(response, "gaps")
  return response
}
export const fetchBackfills = async (
  session: OAuthSession | null,
  view: BackfillListView = "active",
  before?: string,
) => {
  const response = await operationsRequest<BackfillListResponse>(
    session,
    listPath("/v1/operations/backfills", { view, before }),
  )
  assertListResponse(response, "backfills")
  return response
}
export const fetchAlerts = async (session: OAuthSession | null, view: AlertListView = "active", before?: string) => {
  const response = await operationsRequest<AlertListResponse>(
    session,
    listPath("/v1/operations/alerts", { view, before }),
  )
  assertListResponse(response, "alerts")
  return response
}
export const fetchCommands = async (session: OAuthSession | null, before?: string) => {
  const response = await operationsRequest<CommandListResponse>(
    session,
    listPath("/v1/operations/commands", { before }),
  )
  assertListResponse(response, "commands")
  return response
}
export const fetchIngestionEndpoints = async (session: OAuthSession | null, before?: string) => {
  const response = await operationsRequest<EndpointListResponse>(
    session,
    listPath("/v1/operations/ingestion/endpoints", { before }),
  )
  assertListResponse(response, "endpoints")
  return response
}
export type OperationsEvent = { id?: string; type?: string; data?: unknown }

export async function subscribeOperationsEvents({
  session,
  path,
  lastEventId,
  signal,
  onConnected,
  onTransportActivity,
  onEvent,
}: {
  session: OAuthSession
  path: string
  lastEventId?: string
  signal: AbortSignal
  onConnected?: () => void
  onTransportActivity?: () => void
  onEvent: (event: OperationsEvent) => void
}) {
  const headers = new Headers({ Accept: "text/event-stream", "X-Request-ID": requestId(), traceparent: traceparent() })
  if (lastEventId) headers.set("Last-Event-ID", lastEventId)
  const response = await authFetch(session, `${gatewayOrigin()}${path}`, { headers, signal })
  if (response.status !== 200 || !response.body)
    throw new OperationsHttpError(response.status, `Operations event stream failed (${response.status})`)
  if (!(response.headers.get("Content-Type") ?? "").toLowerCase().includes("text/event-stream"))
    throw new Error("Operations event stream returned an unexpected content type")

  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader()
  const cancelReader = () => void reader.cancel().catch(() => undefined)
  if (signal.aborted) cancelReader()
  else signal.addEventListener("abort", cancelReader, { once: true })
  onConnected?.()
  if (signal.aborted) {
    await reader.cancel().catch(() => undefined)
    signal.removeEventListener("abort", cancelReader)
    reader.releaseLock()
    return
  }
  let buffer = ""
  try {
    while (!signal.aborted) {
      const { done, value } = await reader.read()
      if (done) break
      if (!value) continue
      onTransportActivity?.()
      buffer += value
      const frames = buffer.split(/\r?\n\r?\n/)
      buffer = frames.pop() ?? ""
      for (const frame of frames) {
        const parsed = parseEventFrame(frame)
        if (parsed) onEvent(parsed)
      }
    }
  } finally {
    signal.removeEventListener("abort", cancelReader)
    reader.releaseLock()
  }
}
export class OperationsForbiddenError extends Error {
  constructor() {
    super("This DID is not authorized for operations access")
  }
}

export class DemoReadOnlyError extends Error {
  constructor() {
    super("Demo data is read-only. No operator action was sent.")
  }
}

export class OperationsHttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly retryAfter?: string,
  ) {
    super(message)
  }
}

function listPath(path: string, options: { before?: string; view?: string } = {}) {
  const parameters = new URLSearchParams({ limit: "100" })
  if (options.before) parameters.set("before", options.before)
  if (options.view) parameters.set("view", options.view)
  return `${path}?${parameters}`
}

function expectedOperationsSuccessStatus(path: string, method = "GET") {
  const normalizedMethod = method.toUpperCase()
  if (normalizedMethod === "POST" && path === "/v1/operations/backfills") return 201
  if (normalizedMethod === "POST" && path === "/v1/operations/ingestion/reconnect") return 202
  if (normalizedMethod === "POST" && /^\/v1\/operations\/alerts\/[^/?]+\/retry$/.test(path)) return 202
  return 200
}

function assertOverviewResponse(value: unknown): asserts value is Overview {
  if (!isRecord(value)) throw new Error("Operations overview was not an object")
  if (
    !Array.isArray(value.services) ||
    !Array.isArray(value.ingestionSources) ||
    !Array.isArray(value.jetstreamEndpoints) ||
    !Array.isArray(value.commands) ||
    !Array.isArray(value.gaps) ||
    !Array.isArray(value.backfills) ||
    !Array.isArray(value.alerts) ||
    !Array.isArray(value.recentTraces) ||
    !Array.isArray(value.metricRollups) ||
    !isDateString(value.refreshedAt)
  )
    throw new Error("Operations overview failed runtime contract validation")

  assertCapabilities(value.capabilities)
  assertCounts(value.counts)
  if (
    !isRecord(value.evidence) ||
    !value.evidence.services ||
    !value.evidence.ingestion ||
    !value.evidence.database
  )
    throw new Error("Operations evidence map failed runtime contract validation")
  Object.values(value.evidence).forEach(assertEvidence)

  const environment = value.capabilities.environment
  value.services.forEach((item: unknown) => assertService(item, environment))
  value.ingestionSources.forEach((item: unknown) => assertStream(item, environment))
  if (value.ingestion !== undefined && value.ingestion !== null) assertStream(value.ingestion, environment)
  value.jetstreamEndpoints.forEach((item: unknown) => assertEndpoint(item, environment))
  value.commands.forEach((item: unknown) => assertCommand(item, environment))
  value.gaps.forEach((item: unknown) => assertGap(item, environment))
  value.backfills.forEach((item: unknown) => assertBackfill(item, environment))
  value.alerts.forEach((item: unknown) => assertAlert(item, environment))
  value.recentTraces.forEach((item: unknown) => assertSpan(item, environment))
  value.metricRollups.forEach((item: unknown) => assertMetric(item, environment))
  if (value.database !== undefined && value.database !== null) assertDatabase(value.database)
}

function assertServiceResponse(
  value: unknown,
): asserts value is ServiceListResponse | AppViewOperationsResponse {
  if (!isRecord(value) || !Array.isArray(value.services))
    throw new Error("Operations services response failed runtime contract validation")
  const environment = operationsEnvironment()
  value.services.forEach((item: unknown) => assertService(item, environment))
  assertEvidence(value.evidence)
}

function assertIngestionResponse(value: unknown): asserts value is IngestionResponse {
  if (!isRecord(value) || !Array.isArray(value.sources))
    throw new Error("Operations ingestion response failed runtime contract validation")
  const environment = operationsEnvironment()
  if (value.state !== undefined && value.state !== null) assertStream(value.state, environment)
  value.sources.forEach((item: unknown) => assertStream(item, environment))
  assertEvidence(value.evidence)
}

function assertListResponse(
  value: unknown,
  namedKey: "gaps" | "backfills" | "alerts" | "commands" | "endpoints",
) {
  if (!isRecord(value)) throw new Error(`Operations ${namedKey} response was not an object`)
  const items = value[namedKey]
  if (!Array.isArray(items))
    throw new Error(`Operations ${namedKey} response failed runtime contract validation`)
  if (value.nextCursor !== undefined && value.nextCursor !== null && typeof value.nextCursor !== "string")
    throw new Error(`Operations ${namedKey} cursor failed runtime contract validation`)
  if (!isNonNegativeInteger(value.totalCount))
    throw new Error(`Operations ${namedKey} count failed runtime contract validation`)
  const expectedEnvironment = operationsEnvironment()
  if (namedKey === "gaps") items.forEach((item) => assertGap(item, expectedEnvironment))
  if (namedKey === "backfills") items.forEach((item) => assertBackfill(item, expectedEnvironment))
  if (namedKey === "alerts") items.forEach((item) => assertAlert(item, expectedEnvironment))
  if (namedKey === "commands")
    items.forEach((item) => assertCommand(item, expectedEnvironment))
  if (namedKey === "endpoints") items.forEach((item) => assertEndpoint(item, expectedEnvironment))
  assertEvidence(value.evidence)
}

async function validatedTracePage(request: Promise<TraceListResponse>) {
  const response = await request
  if (
    !isRecord(response) ||
    !Array.isArray(response.traces) ||
    !isNonNegativeInteger(response.totalCount) ||
    typeof response.truncated !== "boolean"
  )
    throw new Error("Operations trace response failed runtime contract validation")
  if (response.nextCursor !== undefined && response.nextCursor !== null && typeof response.nextCursor !== "string")
    throw new Error("Operations trace cursor failed runtime contract validation")
  response.traces.forEach((item) => assertSpan(item, operationsEnvironment()))
  assertEvidence(response.evidence)
  return response
}

const healthStates = new Set(["healthy", "degraded", "unhealthy", "unknown"])
const connectionStates = new Set(["connected", "disconnected", "reconnecting", "unknown"])
const commandStatuses = new Set(["queued", "running", "completed", "failed"])
const gapStatuses = new Set([
  "suspected",
  "confirmed",
  "backfill_queued",
  "backfilling",
  "verification_required",
  "resolved",
  "ignored",
])
const backfillStatuses = new Set(["queued", "running", "paused", "completed", "failed", "cancelled"])
const sourceModes = new Set(["tap_verified_resync", "jetstream_replay", "pds_reconciliation"])
const verificationStatuses = new Set(["pending", "required", "verified", "failed"])
const alertStatuses = new Set(["open", "acknowledged", "resolved"])

function assertEvidence(value: unknown) {
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.source) ||
    !new Set(["exact", "sampled", "estimated", "unavailable"]).has(String(value.accuracy)) ||
    !isDateString(value.generatedAt) ||
    !isFiniteNonNegative(value.ageSeconds) ||
    !isDateString(value.validUntil) ||
    (value.indexedThrough !== undefined && value.indexedThrough !== null && !isDateString(value.indexedThrough)) ||
    (value.coverage !== undefined &&
      value.coverage !== null &&
      (!isFiniteNonNegative(value.coverage) || value.coverage > 1)) ||
    (value.lastSuccessfulAt !== undefined && value.lastSuccessfulAt !== null && !isDateString(value.lastSuccessfulAt)) ||
    (value.degradedReason !== undefined && value.degradedReason !== null && !isNonEmptyString(value.degradedReason)) ||
    (value.accuracy === "unavailable" && !isNonEmptyString(value.degradedReason))
  )
    throw new Error("Operations evidence failed runtime contract validation")
}

function assertDryRun(value: unknown) {
  const uncertaintyValid =
    value &&
    isRecord(value) &&
    (value.uncertainty === undefined ||
      value.uncertainty === null ||
      (isRecord(value.uncertainty) &&
        isNonNegativeInteger(value.uncertainty.lowerBound) &&
        isNonNegativeInteger(value.uncertainty.upperBound) &&
        value.uncertainty.lowerBound <= value.uncertainty.upperBound))
  if (
    !isRecord(value) ||
    !isNonNegativeInteger(value.estimatedCount) ||
    !isNonNegativeInteger(value.estimatedDurationSeconds) ||
    !Array.isArray(value.conflicts) ||
    value.conflicts.some((conflict) => typeof conflict !== "string") ||
    typeof value.unresolvedDeletesWarning !== "boolean" ||
    !isNonEmptyString(value.requestFingerprint) ||
    !isDateString(value.validUntil) ||
    !isNonEmptyString(value.methodology) ||
    !isNonEmptyString(value.confidence) ||
    !new Set(["observed", "modeled"]).has(String(value.estimateKind)) ||
    !uncertaintyValid
  )
    throw new Error("Operations backfill dry run failed runtime contract validation")
}

function assertCapabilities(value: unknown): asserts value is Overview["capabilities"] {
  if (
    !isRecord(value) ||
    value.environment !== operationsEnvironment() ||
    !isDateString(value.generatedAt)
  )
    throw new Error("Operations capabilities failed runtime contract validation")
  const capabilities = [value.telemetry, value.recovery, value.alertDelivery]
  if (!isRecord(value.recoveryModes)) throw new Error("Operations recovery modes failed runtime contract validation")
  capabilities.push(
    value.recoveryModes.tapVerifiedResync,
    value.recoveryModes.jetstreamReplay,
    value.recoveryModes.pdsReconciliation,
  )
  capabilities.forEach(assertCapability)
  if (
    !isRecord(value.eventStream) ||
    value.eventStream.path !== "/v1/operations/events/stream" ||
    !isNonNegativeInteger(value.eventStream.retryMilliseconds) ||
    value.eventStream.retryMilliseconds < 1_000 ||
    !isNonNegativeInteger(value.eventStream.fallbackPollMilliseconds) ||
    value.eventStream.fallbackPollMilliseconds < 1_000 ||
    value.eventStream.fallbackPollMilliseconds > 5_000
  )
    throw new Error("Operations event-stream capability failed runtime contract validation")
  assertCapability(value.eventStream)
}

function assertCapability(value: unknown) {
  if (
    !isRecord(value) ||
    typeof value.enabled !== "boolean" ||
    (!value.enabled && !isNonEmptyString(value.disabledReason))
  )
    throw new Error("Operations capability failed runtime contract validation")
}

function assertCounts(value: unknown) {
  if (
    !isRecord(value) ||
    ["activeGaps", "activeBackfills", "attentionBackfills", "completedBackfills", "unresolvedAlerts"].some(
      (key) => !isNonNegativeInteger(value[key]),
    )
  )
    throw new Error("Operations lifecycle counts failed runtime contract validation")
}

function assertService(value: unknown, environment: string) {
  if (
    !isRecord(value) ||
    value.environment !== environment ||
    !isNonEmptyString(value.service) ||
    !isNonEmptyString(value.instanceId) ||
    !healthStates.has(String(value.liveness)) ||
    !healthStates.has(String(value.readiness)) ||
    !healthStates.has(String(value.freshness)) ||
    !healthStates.has(String(value.completeness)) ||
    !isStringRecord(value.dependencyState) ||
    !isOptionalString(value.version) ||
    !isDateString(value.startedAt) ||
    !isDateString(value.heartbeatAt)
  )
    throw new Error("Operations service evidence failed runtime contract validation")
}

function assertStream(value: unknown, environment: string) {
  if (
    !isRecord(value) ||
    value.environment !== environment ||
    !isNonEmptyString(value.source) ||
    !connectionStates.has(String(value.connectionState)) ||
    !isNonNegativeInteger(value.version) ||
    !isNonNegativeInteger(value.queueDepth) ||
    !isDateString(value.heartbeatAt) ||
    !isOptionalDateString(value.connectedAt) ||
    !isOptionalDateString(value.lastDisconnectAt) ||
    !isOptionalString(value.lastDisconnectReason) ||
    !isOptionalNonNegativeInteger(value.lastReceivedCursor) ||
    !isOptionalDateString(value.lastReceivedEventAt) ||
    !isOptionalDateString(value.lastReceivedAt) ||
    !isOptionalNonNegativeInteger(value.lastCommittedCursor) ||
    !isOptionalDateString(value.lastCommittedEventAt) ||
    !isOptionalDateString(value.lastCommittedAt) ||
    !isOptionalNonNegativeInteger(value.queueCapacity) ||
    !isOptionalNonNegativeInteger(value.queueOverflowTotal) ||
    !isOptionalDateString(value.transportHeartbeatAt) ||
    !isOptionalDateString(value.lastIndexedMutationAt) ||
    !isOptionalString(value.projectionWatermark) ||
    !isOptionalString(value.validationWatermark)
  )
    throw new Error("Operations ingestion source failed runtime contract validation")
  if (value.queueEvidence !== undefined && value.queueEvidence !== null) assertEvidence(value.queueEvidence)
}

function assertEndpoint(value: unknown, environment: string) {
  if (
    !isRecord(value) ||
    value.environment !== environment ||
    !isNonEmptyString(value.id) ||
    !isNonEmptyString(value.displayName) ||
    !isNonEmptyString(value.host) ||
    !new Set(["active", "standby"]).has(String(value.role)) ||
    !connectionStates.has(String(value.connectionState)) ||
    !isNonNegativeInteger(value.connectionAttempts) ||
    !isNonNegativeInteger(value.failoverCount) ||
    !isDateString(value.updatedAt) ||
    !isNonNegativeInteger(value.version) ||
    !isOptionalDateString(value.lastConnectedAt) ||
    !isOptionalDateString(value.lastDisconnectedAt) ||
    !isOptionalString(value.lastError)
  )
    throw new Error("Operations endpoint failed runtime contract validation")
}

function assertVersionedStatus(
  value: unknown,
  environment: string,
  statuses: Set<string>,
  label: string,
  enforceEnvironment = true,
) {
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.environment) ||
    (enforceEnvironment && value.environment !== environment) ||
    !isNonNegativeInteger(value.version) ||
    !statuses.has(String(value.status))
  )
    throw new Error(`Operations ${label} failed runtime contract validation`)
}

function assertCommand(value: unknown, environment: string) {
  assertVersionedStatus(value, environment, commandStatuses, "command")
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.id) ||
    value.action !== "reconnect_jetstream" ||
    !isNonEmptyString(value.requestedByDid) ||
    !isOptionalString(value.auditNote) ||
    !isOptionalString(value.claimedBy) ||
    !isOptionalDateString(value.leaseExpiresAt) ||
    !isOptionalString(value.failureReason) ||
    !isDateString(value.createdAt) ||
    !isDateString(value.updatedAt) ||
    !isOptionalDateString(value.completedAt)
  )
    throw new Error("Operations command failed runtime contract validation")
}

function assertGap(value: unknown, environment: string, enforceEnvironment = true) {
  assertVersionedStatus(value, environment, gapStatuses, "gap", enforceEnvironment)
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.id) ||
    !isNonEmptyString(value.source) ||
    !isNonEmptyString(value.reason) ||
    !isStringArray(value.collections) ||
    !isDateString(value.detectedAt) ||
    !isDateString(value.updatedAt) ||
    !isOptionalNonNegativeInteger(value.startCursor) ||
    !isOptionalNonNegativeInteger(value.endCursor) ||
    !isOptionalDateString(value.startTime) ||
    !isOptionalDateString(value.endTime) ||
    !isOptionalString(value.backfillJobId) ||
    !isNonNegativeInteger(value.discoveredCount) ||
    !isNonNegativeInteger(value.processedCount) ||
    !isNonNegativeInteger(value.failedCount) ||
    !isNonNegativeInteger(value.reconciledCount)
  )
    throw new Error("Operations gap failed runtime contract validation")
}

function assertGapInvestigation(value: unknown, environment: string) {
  if (
    !isRecord(value) ||
    !isDateString(value.windowStart) ||
    !isDateString(value.windowEnd) ||
    Date.parse(value.windowStart) > Date.parse(value.windowEnd) ||
    !isRecord(value.assessment) ||
    !isNonEmptyString(value.assessment.title) ||
    !new Set(["high", "medium", "low", "insufficient"]).has(String(value.assessment.confidence)) ||
    !isNonEmptyString(value.assessment.summary) ||
    !isStringArray(value.assessment.evidenceIds) ||
    !isStringArray(value.assessment.limitations) ||
    !Array.isArray(value.evidence) ||
    !isStringArray(value.recommendedActions)
  )
    throw new Error("Gap investigation failed runtime contract validation")

  assertGap(value.gap, environment)
  for (const item of value.evidence) {
    if (
      !isRecord(item) ||
      !isNonEmptyString(item.id) ||
      !new Set(["gap", "stream", "indexing", "service", "alert", "trace"]).has(String(item.kind)) ||
      !isDateString(item.occurredAt) ||
      !isNonEmptyString(item.service) ||
      !isNonEmptyString(item.title) ||
      typeof item.detail !== "string" ||
      !isStringRecord(item.attributes) ||
      !isOptionalString(item.traceId)
    )
      throw new Error("Gap investigation failed runtime contract validation")
  }
}

function assertBackfill(value: unknown, environment: string, enforceEnvironment = true) {
  assertVersionedStatus(value, environment, backfillStatuses, "backfill", enforceEnvironment)
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.id) ||
    !sourceModes.has(String(value.sourceMode)) ||
    !verificationStatuses.has(String(value.verificationStatus)) ||
    typeof value.scopeTruncated !== "boolean" ||
    !isOptionalString(value.gapId) ||
    !isOptionalNonNegativeInteger(value.startCursor) ||
    !isOptionalNonNegativeInteger(value.endCursor) ||
    !isOptionalNonNegativeInteger(value.checkpointCursor) ||
    !isStringArray(value.collections) ||
    !isStringArray(value.authorDids) ||
    !Array.isArray(value.authorResults) ||
    !isPositiveInteger(value.batchSize) ||
    !isPositiveInteger(value.rateLimit) ||
    !isPositiveInteger(value.maxConcurrency) ||
    !isNonNegativeInteger(value.estimatedCount) ||
    !isNonNegativeInteger(value.processedCount) ||
    !isNonNegativeInteger(value.failedCount) ||
    !isNonNegativeInteger(value.reconciledCount) ||
    !isNonEmptyString(value.requestedByDid) ||
    !isOptionalString(value.auditNote) ||
    !isOptionalString(value.failureReason) ||
    !isOptionalString(value.leaseOwner) ||
    !isOptionalDateString(value.leaseExpiresAt) ||
    !isDateString(value.createdAt) ||
    !isDateString(value.updatedAt) ||
    !isOptionalDateString(value.completedAt) ||
    !isOptionalString(value.verificationReason) ||
    !isOptionalString(value.validationWatermark)
  )
    throw new Error("Operations backfill failed runtime contract validation")
  value.authorResults.forEach(assertBackfillAuthorResult)
}

function assertAlert(value: unknown, environment: string, enforceEnvironment = true) {
  assertVersionedStatus(value, environment, alertStatuses, "alert", enforceEnvironment)
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.id) ||
    !isNonEmptyString(value.rule) ||
    !isNonEmptyString(value.conditionKey) ||
    !isNonEmptyString(value.severity) ||
    !isNonEmptyString(value.summary) ||
    !isStringRecord(value.evidence) ||
    !isNonEmptyString(value.runbookSlug) ||
    !isDateString(value.openedAt) ||
    !isDateString(value.updatedAt) ||
    !isOptionalString(value.acknowledgedByDid) ||
    !isOptionalString(value.resolvedByDid) ||
    !isNonNegativeInteger(value.deliveryAttempts) ||
    !isOptionalString(value.lastDeliveryError) ||
    !isOptionalDateString(value.nextDeliveryAt) ||
    !isOptionalDateString(value.deliveryDeadLetteredAt)
  )
    throw new Error("Operations alert failed runtime contract validation")
}

function assertSpan(value: unknown, environment: string, enforceEnvironment = true) {
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.environment) ||
    (enforceEnvironment && value.environment !== environment) ||
    !isNonEmptyString(value.id) ||
    !isNonEmptyString(value.traceId) ||
    !isOptionalString(value.parentSpanId) ||
    !isNonEmptyString(value.service) ||
    !isNonEmptyString(value.name) ||
    !isDateString(value.startedAt) ||
    !isFiniteNonNegative(value.durationMs) ||
    !isNonEmptyString(value.status) ||
    !isStringRecord(value.attributes) ||
    !isDateString(value.expiresAt)
  )
    throw new Error("Operations trace span failed runtime contract validation")
}

function assertMetric(value: unknown, environment: string, enforceEnvironment = true) {
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.environment) ||
    (enforceEnvironment && value.environment !== environment) ||
    !isNonEmptyString(value.metricName) ||
    !isDateString(value.bucketStart) ||
    !isStringRecord(value.dimensions) ||
    !isNonNegativeInteger(value.sampleCount) ||
    !isFiniteNumber(value.valueSum) ||
    !isOptionalFiniteNumber(value.valueMin) ||
    !isOptionalFiniteNumber(value.valueMax)
  )
    throw new Error("Operations metric rollup failed runtime contract validation")
}

function assertBackfillAuthorResult(value: unknown) {
  if (
    !isRecord(value) ||
    !isNonEmptyString(value.did) ||
    !value.did.startsWith("did:") ||
    !isNonEmptyString(value.collection) ||
    !isNonNegativeInteger(value.discoveredCount) ||
    !isNonNegativeInteger(value.processedCount) ||
    !isNonNegativeInteger(value.failedCount) ||
    value.processedCount > value.discoveredCount ||
    value.failedCount !== value.discoveredCount - value.processedCount ||
    typeof value.capped !== "boolean" ||
    typeof value.truncated !== "boolean" ||
    !new Set(["succeeded", "partial", "failed", "cancelled", "unsupported"]).has(String(value.status)) ||
    !isOptionalString(value.error)
  )
    throw new Error("Operations backfill author result failed runtime contract validation")
}

function assertDatabase(value: unknown) {
  if (
    !isRecord(value) ||
    !isNonNegativeInteger(value.databaseSizeBytes) ||
    !isNonNegativeInteger(value.activeConnections) ||
    !isNonNegativeInteger(value.maxConnections) ||
    !isNonNegativeInteger(value.transactionsTotal) ||
    !isNonNegativeInteger(value.estimatedRecords) ||
    !isOptionalFiniteNonNegative(value.cacheHitRatio) ||
    (typeof value.cacheHitRatio === "number" && value.cacheHitRatio > 1) ||
    !isOptionalDateString(value.statsResetAt) ||
    !Array.isArray(value.topTables) ||
    !isNonNegativeInteger(value.connectedBackends) ||
    !isNonNegativeInteger(value.activeQueries) ||
    !isOptionalFiniteNonNegative(value.transactionRatePerSecond) ||
    !isDateString(value.observedAt) ||
    !isFiniteNonNegative(value.evidenceAgeSeconds)
  )
    throw new Error("Operations database observation failed runtime contract validation")
  for (const table of value.topTables) {
    if (
      !isRecord(table) ||
      !isNonEmptyString(table.schema) ||
      !isNonEmptyString(table.table) ||
      !isNonNegativeInteger(table.estimatedRecords)
    )
      throw new Error("Operations database table estimate failed runtime contract validation")
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value)
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0
}

function isOptionalString(value: unknown): value is string | null | undefined {
  return value === undefined || value === null || typeof value === "string"
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string")
}

function isStringRecord(value: unknown): value is Record<string, string> {
  return isRecord(value) && Object.values(value).every((item) => typeof item === "string")
}

function isDateString(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value))
}

function isOptionalDateString(value: unknown): value is string | null | undefined {
  return value === undefined || value === null || isDateString(value)
}

function isFiniteNonNegative(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value)
}

function isOptionalFiniteNumber(value: unknown): value is number | null | undefined {
  return value === undefined || value === null || isFiniteNumber(value)
}

function isOptionalFiniteNonNegative(value: unknown): value is number | null | undefined {
  return value === undefined || value === null || isFiniteNonNegative(value)
}

function isNonNegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0
}

function isPositiveInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) > 0
}

function isOptionalNonNegativeInteger(value: unknown): value is number | null | undefined {
  return value === undefined || value === null || isNonNegativeInteger(value)
}

function parseEventFrame(frame: string): OperationsEvent | undefined {
  let id: string | undefined
  let type: string | undefined
  const data: string[] = []
  for (const line of frame.split(/\r?\n/)) {
    if (line.startsWith("id:")) id = line.slice(3).trim()
    else if (line.startsWith("event:")) type = line.slice(6).trim()
    else if (line.startsWith("data:")) data.push(line.slice(5).trimStart())
  }
  if (!data.length || isTransportOnlyEvent(type)) return undefined
  if (id !== undefined && !/^(0|[1-9]\d*)$/.test(id)) return undefined
  const raw = data.join("\n")
  if (!raw) return undefined
  let payload: unknown
  try {
    payload = JSON.parse(raw)
  } catch {
    return undefined
  }
  return { id, type, data: payload }
}

function isTransportOnlyEvent(type?: string) {
  return type !== undefined && ["heartbeat", "keepalive", "ping"].includes(type.toLowerCase())
}
