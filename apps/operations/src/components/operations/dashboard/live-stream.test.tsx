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
    expect(screen.getByText("2,100,333 μs")).toBeTruthy()
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
})
