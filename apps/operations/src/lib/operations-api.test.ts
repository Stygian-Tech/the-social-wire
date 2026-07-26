import { afterEach, expect, test } from "bun:test"
import { operationsEnvironment } from "@/lib/app-environment"
import {
  DemoReadOnlyError,
  dryRunBackfill,
  fetchAppViewOperations,
  fetchAlerts,
  fetchBackfills,
  fetchCommands,
  fetchGapInvestigation,
  fetchIngestion,
  fetchIngestionEndpoints,
  fetchRecentTraces,
  fetchServices,
  gatewayOrigin,
  OperationsHttpError,
  operationsRequest,
  subscribeOperationsEvents,
} from "@/lib/operations-api"
import type { OAuthSession } from "@/lib/auth"
import { demoGapInvestigation, demoOverview } from "@/lib/demo-data"

const evidence = demoOverview.evidence.overview

const originalAppEnv = process.env.NEXT_PUBLIC_APP_ENV
const originalServerAppEnv = process.env.APP_ENV
const originalGatewayOrigin = process.env.NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN
const originalDemoMode = process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
afterEach(() => {
  restoreEnvironment("NEXT_PUBLIC_APP_ENV", originalAppEnv)
  restoreEnvironment("APP_ENV", originalServerAppEnv)
  restoreEnvironment("NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN", originalGatewayOrigin)
  restoreEnvironment("NEXT_PUBLIC_OPERATIONS_DEMO_MODE", originalDemoMode)
})

test("demo mode never reports a fake successful mutation", async () => {
  process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE = "1"
  expect(
    operationsRequest(null, "/v1/operations/ingestion/reconnect", { method: "POST", body: "{}" }),
  ).rejects.toBeInstanceOf(DemoReadOnlyError)
  expect(
    dryRunBackfill(null, {
      sourceMode: "jetstream_replay",
      collections: ["site.standard.document"],
      authorDids: [],
      batchSize: 100,
      rateLimit: 100,
      maxConcurrency: 1,
    }),
  ).rejects.toBeInstanceOf(DemoReadOnlyError)
})

test("parses resumable authenticated event-stream frames", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const events: unknown[] = []
  let connected = false
  const session = {
    fetchHandler: async () =>
      new Response("id: 2\nevent: gap.changed\ndata: {\"gapId\":\"gap-1\"}\n\n", {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      }),
  } as unknown as OAuthSession

  await subscribeOperationsEvents({
    session,
    path: "/v1/operations/events/stream",
    signal: new AbortController().signal,
    onConnected: () => {
      connected = true
    },
    onEvent: (event) => events.push(event),
  })

  expect(connected).toBe(true)
  expect(events).toEqual([{ id: "2", type: "gap.changed", data: { gapId: "gap-1" } }])
})

test("keeps partial frames buffered and treats comments, heartbeat events, and malformed data as transport-only", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const encoder = new TextEncoder()
  const chunks = [
    ": heartbeat\n\nid: 3\nevent: gap.changed\ndata: {\"gap",
    "Id\":\"gap-2\"}\n\nevent: heartbeat\ndata: {}\n\nid: 4\nevent: gap.changed\ndata: {malformed}\n\nid: event-5\nevent: gap.changed\ndata: {\"gapId\":\"gap-3\"}\n\n",
  ]
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      const chunk = chunks.shift()
      if (chunk === undefined) controller.close()
      else controller.enqueue(encoder.encode(chunk))
    },
  })
  const session = {
    fetchHandler: async () =>
      new Response(stream, { status: 200, headers: { "Content-Type": "text/event-stream" } }),
  } as unknown as OAuthSession
  const events: unknown[] = []
  let activityCount = 0

  await subscribeOperationsEvents({
    session,
    path: "/v1/operations/events/stream",
    signal: new AbortController().signal,
    onTransportActivity: () => {
      activityCount += 1
    },
    onEvent: (event) => events.push(event),
  })

  expect(activityCount).toBe(2)
  expect(events).toEqual([{ id: "3", type: "gap.changed", data: { gapId: "gap-2" } }])
})

test("surfaces expired event cursors as 410 without consuming a fake stream", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const session = {
    fetchHandler: async () => Response.json({ error: "expired_cursor" }, { status: 410 }),
  } as unknown as OAuthSession

  const request = subscribeOperationsEvents({
    session,
    path: "/v1/operations/events/stream",
    lastEventId: "expired-event",
    signal: new AbortController().signal,
    onEvent: () => undefined,
  })

  expect(request).rejects.toMatchObject({ status: 410 } satisfies Partial<OperationsHttpError>)
})

test("cancels an open event-stream reader when its request is aborted", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const controller = new AbortController()
  let cancelled = false
  const stream = new ReadableStream<Uint8Array>({
    cancel() {
      cancelled = true
    },
  })
  const session = {
    fetchHandler: async () =>
      new Response(stream, { status: 200, headers: { "Content-Type": "text/event-stream" } }),
  } as unknown as OAuthSession

  await subscribeOperationsEvents({
    session,
    path: "/v1/operations/events/stream",
    signal: controller.signal,
    onConnected: () => controller.abort(),
    onEvent: () => undefined,
  })

  expect(cancelled).toBe(true)
})

test("uses the deployment's single configured gateway origin", () => {
  process.env.NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN = "https://operations-gateway.example"
  expect(gatewayOrigin()).toBe("https://operations-gateway.example")
})

test("derives the fixed operations environment from APP_ENV", () => {
  process.env.NEXT_PUBLIC_APP_ENV = "prod"
  expect(operationsEnvironment()).toBe("prod")

  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  expect(operationsEnvironment()).toBe("dev")
})

test("fails closed when the operations environment is missing or invalid", () => {
  delete process.env.NEXT_PUBLIC_APP_ENV
  delete process.env.APP_ENV
  expect(() => operationsEnvironment()).toThrow("APP_ENV is required")

  process.env.NEXT_PUBLIC_APP_ENV = "test"
  expect(() => operationsEnvironment()).toThrow("must be exactly dev or prod")
})

test("defaults the gateway origin from the fixed environment", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN
  process.env.NEXT_PUBLIC_APP_ENV = "prod"
  expect(gatewayOrigin()).toBe("https://api.thesocialwire.app")

  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  expect(gatewayOrigin()).toBe("https://api.testing.thesocialwire.app")
})

test("operations requests propagate request and W3C trace identifiers", async () => {
  let headers = new Headers()
  const session = {
    fetchHandler: async (_url: string, init?: RequestInit) => {
      headers = new Headers(init?.headers)
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    },
  } as unknown as OAuthSession

  await operationsRequest(session, "/v1/operations/gaps")

  expect(headers.get("X-Request-ID")).toBeTruthy()
  expect(headers.get("traceparent")).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)
})

test("accepts a deeply validated lightweight overview with empty named preview lists", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  const lightweightOverview = {
    ...demoOverview,
    jetstreamEndpoints: [],
    commands: [],
    gaps: [],
    backfills: [],
    alerts: [],
    recentTraces: [],
    metricRollups: [],
  }
  const session = jsonSession(lightweightOverview)

  const response = await operationsRequest(session, "/v1/operations/overview")

  expect(response).toEqual(lightweightOverview)
})

test("rejects an overview that omits a named preview list", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const { gaps: _gaps, ...invalid } = demoOverview
  void _gaps
  expect(operationsRequest(jsonSession(invalid), "/v1/operations/overview")).rejects.toThrow(
    "Operations overview failed runtime contract validation",
  )
})

test("rejects overview evidence without its validity and age contract", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const invalid = {
    ...demoOverview,
    evidence: {
      ...demoOverview.evidence,
      services: {
        source: "test",
        accuracy: "exact",
        generatedAt: new Date().toISOString(),
      },
    },
  }

  expect(operationsRequest(jsonSession(invalid), "/v1/operations/overview")).rejects.toThrow(
    "Operations evidence failed runtime contract validation",
  )
})

test("rejects an overview without the service, ingestion, and database evidence guaranteed by the service", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const invalid = { ...demoOverview, evidence: {} }

  expect(operationsRequest(jsonSession(invalid), "/v1/operations/overview")).rejects.toThrow(
    "Operations evidence map failed runtime contract validation",
  )
})

test("rejects overview evidence from a different database environment", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  const invalid = {
    ...demoOverview,
    capabilities: { ...demoOverview.capabilities, environment: "prod" },
  }

  expect(operationsRequest(jsonSession(invalid), "/v1/operations/overview")).rejects.toThrow(
    "Operations capabilities failed runtime contract validation",
  )
})

test("uses explicit lifecycle views and opaque before cursors", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  let requestedURL = ""
  const item = demoOverview.backfills.find(({ status }) => status === "failed")!
  const session = {
    fetchHandler: async (url: string) => {
      requestedURL = url
      return Response.json({ backfills: [item], totalCount: 1, evidence })
    },
  } as unknown as OAuthSession

  await fetchBackfills(session, "needs_attention", "opaque-page-cursor")

  const url = new URL(requestedURL)
  expect(url.searchParams.get("view")).toBe("needs_attention")
  expect(url.searchParams.get("before")).toBe("opaque-page-cursor")
  expect(url.searchParams.has("cursor")).toBe(false)
})

test("uses server-side alert lifecycle views before pagination", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  let requestedURL = ""
  const alert = { ...demoOverview.alerts[0]!, id: "resolved-alert", status: "resolved" as const }
  const session = {
    fetchHandler: async (url: string) => {
      requestedURL = url
      return Response.json({ alerts: [alert], totalCount: 1, evidence })
    },
  } as unknown as OAuthSession

  await fetchAlerts(session, "history", "opaque-alert-cursor")

  const url = new URL(requestedURL)
  expect(url.searchParams.get("view")).toBe("history")
  expect(url.searchParams.get("before")).toBe("opaque-alert-cursor")
})

test("validates named command and endpoint drill-down wrappers", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  const command = demoOverview.commands[0] ?? {
    id: "command-1",
    action: "reconnect_jetstream" as const,
    status: "completed" as const,
    requestedByDid: "did:plc:operator",
    createdAt: "2026-07-22T01:00:00Z",
    updatedAt: "2026-07-22T01:00:01Z",
    version: 1,
    environment: "dev",
  }
  const endpoint = demoOverview.jetstreamEndpoints[0]!

  await expect(fetchCommands(jsonSession({ commands: [command], totalCount: 1, evidence }))).resolves.toMatchObject({
    commands: [command],
  })
  await expect(fetchIngestionEndpoints(jsonSession({ endpoints: [endpoint], totalCount: 1, evidence }))).resolves.toMatchObject({
    endpoints: [endpoint],
  })
})

test("validates evidence on direct service, ingestion, and AppView responses", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  await expect(fetchServices(jsonSession({ services: demoOverview.services, evidence }))).resolves.toBeTruthy()
  await expect(
    fetchIngestion(
      jsonSession({ state: demoOverview.ingestion, sources: demoOverview.ingestionSources, evidence }),
    ),
  ).resolves.toBeTruthy()
  await expect(
    fetchAppViewOperations(jsonSession({ services: demoOverview.services.slice(0, 2), evidence })),
  ).resolves.toBeTruthy()

  expect(fetchServices(jsonSession({ services: demoOverview.services }))).rejects.toThrow(
    "Operations evidence failed runtime contract validation",
  )
})

test("requires trace truncation and evidence metadata", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  const traces = demoOverview.recentTraces.slice(0, 1)
  expect(fetchRecentTraces(jsonSession({ traces, totalCount: 1 }))).rejects.toThrow(
    "Operations trace response failed runtime contract validation",
  )
  expect(
    fetchRecentTraces(jsonSession({ traces, totalCount: 1, truncated: false, evidence })),
  ).resolves.toMatchObject({ traces, truncated: false })
})

test("rejects lifecycle rows with an invalid status or missing environment version evidence", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const item = demoOverview.backfills[0]!
  const invalid = { ...item, environment: undefined, version: undefined, status: "finished" }

  expect(fetchBackfills(jsonSession({ backfills: [invalid], totalCount: 1, evidence }), "history")).rejects.toThrow(
    "Operations backfill failed runtime contract validation",
  )
})

test("rejects generic list wrappers instead of silently normalizing contract drift", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  const item = demoOverview.backfills[0]!

  expect(fetchBackfills(jsonSession({ items: [item], totalCount: 1, evidence }), "active")).rejects.toThrow(
    "Operations backfills response failed runtime contract validation",
  )
})

test("rejects named list pages without the common evidence envelope", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  expect(fetchBackfills(jsonSession({ backfills: [], totalCount: 0 }), "active")).rejects.toThrow(
    "Operations evidence failed runtime contract validation",
  )
})

test("validates the complete gap investigation response", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  const gapId = demoOverview.gaps[0]!.id
  const investigation = demoGapInvestigation(gapId)

  await expect(fetchGapInvestigation(jsonSession(investigation), gapId)).resolves.toEqual(investigation)
  await expect(
    fetchGapInvestigation(jsonSession({ ...investigation, assessment: undefined }), gapId),
  ).rejects.toThrow("Gap investigation failed runtime contract validation")
})

test("enforces the exact non-default mutation success statuses", async () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  process.env.NEXT_PUBLIC_APP_ENV = "dev"
  const backfill = demoOverview.backfills[0]!
  const command = demoOverview.commands[0] ?? {
    id: "command-contract-status",
    action: "reconnect_jetstream" as const,
    status: "queued" as const,
    requestedByDid: "did:plc:operator",
    createdAt: "2026-07-22T01:00:00Z",
    updatedAt: "2026-07-22T01:00:00Z",
    version: 0,
    environment: "dev" as const,
  }
  const alert = demoOverview.alerts[0]!

  await expect(
    operationsRequest(jsonSession(backfill), "/v1/operations/backfills", { method: "POST" }),
  ).rejects.toThrow("contract requires 201")
  await expect(
    operationsRequest(jsonSession(backfill, 201), "/v1/operations/backfills", { method: "POST" }),
  ).resolves.toEqual(backfill)

  await expect(
    operationsRequest(jsonSession(command), "/v1/operations/ingestion/reconnect", { method: "POST" }),
  ).rejects.toThrow("contract requires 202")
  await expect(
    operationsRequest(jsonSession(command, 202), "/v1/operations/ingestion/reconnect", { method: "POST" }),
  ).resolves.toEqual(command)

  await expect(
    operationsRequest(jsonSession(alert), `/v1/operations/alerts/${alert.id}/retry`, { method: "POST" }),
  ).rejects.toThrow("contract requires 202")
  await expect(
    operationsRequest(jsonSession(alert, 202), `/v1/operations/alerts/${alert.id}/retry`, { method: "POST" }),
  ).resolves.toEqual(alert)
})

test("rejects incomplete dry-run estimates before they can be fingerprint-bound", () => {
  delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  expect(
    dryRunBackfill(jsonSession({ estimatedCount: 10, conflicts: [] }), {
      sourceMode: "jetstream_replay",
      collections: ["site.standard.document"],
      authorDids: [],
      batchSize: 100,
      rateLimit: 100,
      maxConcurrency: 1,
    }),
  ).rejects.toThrow("Operations backfill dry run failed runtime contract validation")
})

function restoreEnvironment(key: string, value: string | undefined) {
  if (value === undefined) delete process.env[key]
  else process.env[key] = value
}

function jsonSession(value: unknown, status = 200) {
  return {
    fetchHandler: async () => Response.json(value, { status }),
  } as unknown as OAuthSession
}
