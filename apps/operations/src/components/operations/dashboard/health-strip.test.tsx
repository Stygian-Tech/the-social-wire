import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { HealthStrip } from "@/components/operations/dashboard/health-strip"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

describe("HealthStrip", () => {
  it("uses descriptive health dimension titles", () => {
    render(<HealthStrip overview={demoOverview} />)

    expect(screen.getByText("Service Liveness")).toBeTruthy()
    expect(screen.getByText("Traffic Readiness")).toBeTruthy()
    expect(screen.getByText("Ingestion Freshness")).toBeTruthy()
    expect(screen.getByText("Projection Completeness")).toBeTruthy()
  })

  it("renders service health and gap counts from reported evidence", () => {
    render(<HealthStrip overview={demoOverview} />)

    expect(screen.getByText("4 / 4 required services report healthy")).toBeTruthy()
    expect(screen.getByText(/3 active gaps · 1 \/ 1 projection workers complete/)).toBeTruthy()
    expect(screen.getAllByText("Degraded").length).toBeGreaterThan(0)
  })

  it("uses the transport heartbeat when a legitimate quiet source has no new content", () => {
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          services: demoOverview.services.map((service) => ({ ...service, freshness: "healthy" })),
          ingestion: { ...demoOverview.ingestion!, lastCommittedAt: undefined },
        }}
      />,
    )

    expect(screen.getByText(/jetstream transport heartbeat .* worker freshness healthy/)).toBeTruthy()
    expect(screen.getByText("Good")).toBeTruthy()
  })

  it("does not blend Gateway or AppView freshness into ingestion freshness", () => {
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          services: demoOverview.services.map((service) => ({
            ...service,
            freshness: service.service === "appview-worker" ? "healthy" : "unhealthy",
          })),
        }}
      />,
    )

    expect(screen.getByText("Ingestion Freshness").nextElementSibling?.textContent).toBe("Good")
  })

  it("does not blend unmeasured Gateway or AppView completeness into projection completeness", () => {
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          counts: { ...demoOverview.counts, activeGaps: 0 },
          services: demoOverview.services.map((service) => ({
            ...service,
            completeness: service.service === "appview-worker" ? "healthy" : "unknown",
          })),
        }}
      />,
    )

    expect(screen.getByText("Projection Completeness").nextElementSibling?.textContent).toBe("Complete")
  })

  it("ages an expired ingestion heartbeat to Unknown", () => {
    const expiredReference = new Date(new Date(demoOverview.refreshedAt).getTime() + 60_000).toISOString()
    render(<HealthStrip overview={demoOverview} referenceTime={expiredReference} />)

    expect(screen.getByText("Ingestion Freshness").nextElementSibling?.textContent).toBe("Unknown")
  })

  it("shows Reconnecting instead of Disconnected for a recent transition", () => {
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          services: demoOverview.services.map((service) => ({ ...service, freshness: "healthy" })),
          ingestion: {
            ...demoOverview.ingestion!,
            connectionState: "disconnected",
            lastDisconnectAt: demoOverview.refreshedAt,
          },
        }}
      />,
    )

    expect(screen.getByText("Ingestion Freshness").nextElementSibling?.textContent).toBe("Reconnecting")
  })

  it("does not infer transport health from a fresh generic ingestion heartbeat", () => {
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          services: demoOverview.services.map((service) => ({ ...service, freshness: "healthy" })),
          ingestion: { ...demoOverview.ingestion!, transportHeartbeatAt: undefined, heartbeatAt: demoOverview.refreshedAt },
        }}
      />,
    )

    expect(screen.getByText("Ingestion Freshness").nextElementSibling?.textContent).toBe("Unknown")
    expect(screen.getByText("No valid transport heartbeat reported")).toBeTruthy()
  })

  it("requires every logical service even if the only reported service is healthy", () => {
    render(<HealthStrip overview={{ ...demoOverview, services: [demoOverview.services[0]!] }} />)

    expect(screen.getByText("Service Liveness").nextElementSibling?.textContent).toBe("Unknown")
    expect(screen.getByText("1 / 4 required services report healthy")).toBeTruthy()
  })

  it("ignores a stale retired replica when the same logical service has a fresh instance", () => {
    const staleReplica = {
      ...demoOverview.services[0]!,
      instanceId: "retired-gateway",
      liveness: "unhealthy" as const,
      heartbeatAt: new Date(new Date(demoOverview.refreshedAt).getTime() - 86_400_000).toISOString(),
    }
    render(<HealthStrip overview={{ ...demoOverview, services: [...demoOverview.services, staleReplica] }} />)

    expect(screen.getByText("Service Liveness").nextElementSibling?.textContent).toBe("Healthy")
  })
})
