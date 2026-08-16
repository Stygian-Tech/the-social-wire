import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { LiveStream } from "@/components/operations/dashboard/live-stream"
import { OperationsAuthProvider } from "@/lib/auth-context"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)
process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE = "1"

describe("LiveStream", () => {
  function renderStream(data = demoOverview) {
    const queryClient = new QueryClient()
    return render(
      <QueryClientProvider client={queryClient}>
        <OperationsAuthProvider>
          <LiveStream data={data} environment="dev" />
        </OperationsAuthProvider>
      </QueryClientProvider>,
    )
  }

  it("shows only values present in stream telemetry or derived from its timestamps", () => {
    renderStream()

    expect(screen.getByText("Jetstream · unverified supplemental")).toBeTruthy()
    expect(screen.getByText("Legacy V1 Received Cursor (μs)")).toBeTruthy()
    expect(screen.getByText("Legacy V1 Committed Cursor (μs)")).toBeTruthy()
    expect(screen.queryByText("2,100,333 μs")).toBeNull()
    expect(screen.queryByText("dev-js-03")).toBeNull()
    expect(screen.queryByText("410 ms / 1.82 s")).toBeNull()
  })

  it("treats a recent disconnect as reconnecting while polling can bridge the gap", () => {
    renderStream({
      ...demoOverview,
      ingestion: {
        ...demoOverview.ingestion!,
        connectionState: "disconnected",
        lastDisconnectAt: demoOverview.refreshedAt,
      },
    })

    expect(screen.getByText("● reconnecting")).toBeTruthy()
  })

  it("reports disconnected after the reconnecting grace period expires", () => {
    renderStream({
      ...demoOverview,
      ingestion: {
        ...demoOverview.ingestion!,
        connectionState: "disconnected",
        lastDisconnectAt: new Date(new Date(demoOverview.refreshedAt).getTime() - 120_000).toISOString(),
      },
    })

    expect(screen.getByText("● disconnected")).toBeTruthy()
  })

  it("reports unknown when transport evidence is missing even if the generic heartbeat is fresh", () => {
    renderStream({
      ...demoOverview,
      ingestion: { ...demoOverview.ingestion!, transportHeartbeatAt: undefined, heartbeatAt: demoOverview.refreshedAt },
    })

    expect(screen.getByText("● unknown")).toBeTruthy()
  })

  it("withholds expired exact queue evidence", () => {
    const validUntil = "2026-07-22T20:00:15.000Z"
    renderStream({
      ...demoOverview,
      refreshedAt: "2026-07-22T20:00:16.000Z",
      ingestion: {
        ...demoOverview.ingestion!,
        queueDepth: 4,
        queueCapacity: 100,
        queueOverflowTotal: 2,
        queueEvidence: {
          source: "worker_queue",
          accuracy: "exact",
          generatedAt: "2026-07-22T20:00:00.000Z",
          ageSeconds: 0,
          validUntil,
          coverage: 1,
        },
      },
    })

    expect(screen.queryByText("4 / 100")).toBeNull()
    expect(screen.getByText("Processing queue depth is withheld because its exact evidence has expired.")).toBeTruthy()
  })

  it("shows both Jetstream endpoints and the active failover role", () => {
    renderStream()

    expect(screen.getByText("Jetstream 1")).toBeTruthy()
    expect(screen.getByText("Jetstream 2")).toBeTruthy()
    expect(screen.getByText("active")).toBeTruthy()
    expect(screen.getByText("standby")).toBeTruthy()
    expect(screen.getByRole("button", { name: /Reconnect Jetstream/ })).toBeTruthy()
    expect(screen.getByRole("link", { name: "View All Endpoints" }).getAttribute("href")).toBe("/endpoints")
    expect(screen.getByRole("link", { name: "View Command History" }).getAttribute("href")).toBe("/commands")
  })

  it("keeps the operator note optional for a versioned reconnect", () => {
    renderStream({ ...demoOverview, ingestion: { ...demoOverview.ingestion!, connectionState: "disconnected", version: 1 } })

    fireEvent.click(screen.getByRole("button", { name: "Reconnect Jetstream ingestion transport" }))
    const dialog = screen.getByRole("dialog", { name: "Reconnect Jetstream?" })
    expect(within(dialog).getByLabelText(/Operator Audit Note/)).toBeTruthy()
    expect(within(dialog).getByRole("button", { name: "Reconnect Jetstream" }).hasAttribute("disabled")).toBe(false)
  })

  it("shows reconnect progress instead of offering a duplicate command", () => {
    renderStream({
      ...demoOverview,
      commands: [
        {
          id: "command-1",
          environment: "dev",
          version: 1,
          action: "reconnect_jetstream",
          status: "running",
          requestedByDid: "did:plc:operator",
          auditNote: "Reconnect stalled ingestion",
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        },
      ],
    })

    expect(screen.getByText("Reconnect running")).toBeTruthy()
    expect(screen.queryByRole("button", { name: "Reconnect Jetstream" })).toBeNull()
  })

  it("binds reconnect availability to supplemental Jetstream evidence under Tap authority", () => {
    const jetstream = { ...demoOverview.ingestion!, source: "jetstream", version: 7 }
    const tap = { ...demoOverview.ingestion!, source: "tap", version: undefined as unknown as number }
    renderStream({ ...demoOverview, ingestion: tap, ingestionSources: [tap, jetstream] })

    expect(screen.getByRole("button", { name: /Reconnect Jetstream/ }).hasAttribute("disabled")).toBe(false)
  })

  it("presents durable Jetstream V2 inbox authority without legacy cursor semantics", () => {
    const services = demoOverview.services.map((service) => service.service === "appview-worker"
      ? {
          ...service,
          dependencyState: {
            ...service.dependencyState,
            ingestion_authority: "jetstream_v2_inbox",
            jetstream_v2_source_generation: "v2-us-west-1",
          },
        }
      : service)
    renderStream({
      ...demoOverview,
      services,
      ingestion: undefined,
      ingestionSources: [{ ...demoOverview.ingestion!, source: "jetstream", version: 7 }],
      evidence: {
        ...demoOverview.evidence,
        ingestion: {
          ...demoOverview.evidence.ingestion,
          source: "appview_jetstream_checkpoints",
          accuracy: "exact",
          validUntil: demoOverview.refreshedAt,
        },
      },
      durability: {
        environment: "dev",
        checkpoints: [
          {
            environment: "dev",
            sourceGeneration: "retired-v2-generation",
            sourceHost: "jetstream2.us-east.bsky.network",
            streamNSID: "network.bsky.jetstream.subscribeEvents",
            filterFingerprint: "retired-filters",
            cursorKind: "jetstream_v2_seq",
            lastStagedSequence: 9_999,
            lastAppliedSequence: 9_998,
            replayState: "live",
            replayBytesDownloaded: 0,
            replayRetryCount: 0,
            replayRangeResumeCount: 0,
            updatedAt: new Date(new Date(demoOverview.refreshedAt).getTime() + 1_000).toISOString(),
          },
          {
            environment: "dev",
            sourceGeneration: "v2-us-west-1",
            sourceHost: "jetstream.us-west.bsky.network",
            streamNSID: "network.bsky.jetstream.subscribeEvents",
            filterFingerprint: "filters-v1",
            cursorKind: "jetstream_v2_seq",
            lastStagedSequence: 2_100,
            lastAppliedSequence: 2_000,
            replayState: "live",
            replayBytesDownloaded: 0,
            replayRetryCount: 0,
            replayRangeResumeCount: 0,
            intakeHeartbeatAt: demoOverview.refreshedAt,
            updatedAt: demoOverview.refreshedAt,
          },
        ],
        inbox: { pending: 0, leased: 0, retrying: 0, applied: 2_000, deadLetters: 0, total: 2_000 },
        incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
        replayBytesRolling24Hours: 0,
        generatedAt: demoOverview.refreshedAt,
      },
    })

    expect(screen.getByText("Jetstream V2 Inbox · authoritative")).toBeTruthy()
    expect(screen.getByText("V2 Inbox Staged Sequence")).toBeTruthy()
    expect(screen.getByText("V2 Inbox Applied Sequence")).toBeTruthy()
    expect(screen.getByText("2,100")).toBeTruthy()
    expect(screen.getByText("2,000")).toBeTruthy()
    expect(screen.queryByText("9,999")).toBeNull()
    expect(screen.queryByText("9,998")).toBeNull()
    expect(screen.queryByText("Legacy V1 Received Cursor (μs)")).toBeNull()
    expect(screen.queryByText("Legacy V1 Committed Cursor (μs)")).toBeNull()
    expect(screen.queryByRole("button", { name: /Reconnect Jetstream/ })).toBeNull()
  })
})
