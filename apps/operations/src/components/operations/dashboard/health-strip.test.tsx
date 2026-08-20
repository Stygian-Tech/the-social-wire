import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { HealthStrip } from "@/components/operations/dashboard/health-strip"
import { demoOverview } from "@/lib/demo-data"
import { SERVICE_HEALTH_METRIC } from "@/lib/observability-values"

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
    expect(screen.getByText(/3 legacy gap signals · 1 \/ 1 Charybdis projections complete/)).toBeTruthy()
    expect(screen.getAllByText("Degraded").length).toBeGreaterThan(0)
  })

  it("shows the rolling window and does not flip for one degraded refresh", () => {
    const bucketStart = new Date(
      Math.floor(new Date(demoOverview.refreshedAt).getTime() / 60_000) * 60_000 - 60_000,
    ).toISOString()
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          services: demoOverview.services.map((service) => ({
            ...service,
            liveness: service.service === "gateway" ? "degraded" : "healthy",
          })),
          metricRollups: ["gateway", "appview", "appview-worker", "operations"].map((service) => ({
            environment: "dev",
            bucketStart,
            metricName: SERVICE_HEALTH_METRIC,
            dimensions: { service, dimension: "liveness", state: "healthy" },
            sampleCount: 6,
            valueSum: 6,
          })),
        }}
      />,
    )

    expect(screen.getByText("Service Liveness").nextElementSibling?.textContent).toBe("Healthy")
    expect(screen.getByText("5m rolling average · 24 samples")).toBeTruthy()
  })

  it("uses durable incidents and terminal-prefix evidence instead of legacy gap totals", () => {
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          durability: {
            environment: "dev",
            checkpoints: [{
              environment: "dev",
              sourceGeneration: "v2-us-west-1",
              sourceHost: "jetstream.us-west.bsky.network",
              streamNSID: "network.bsky.jetstream.subscribeEvents",
              filterFingerprint: "filters-v1",
              cursorKind: "jetstream_v2_seq",
              lastStagedSequence: 1000,
              lastAppliedSequence: 900,
              replayState: "live",
              replayBytesDownloaded: 0,
              replayRetryCount: 0,
              replayRangeResumeCount: 0,
              intakeHeartbeatAt: demoOverview.refreshedAt,
              updatedAt: demoOverview.refreshedAt,
            }],
            inbox: { pending: 2, leased: 1, retrying: 0, applied: 50, deadLetters: 0, total: 53, oldestPendingAgeSeconds: 2 },
            incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 1, ignored: 0 },
            replayBytesRolling24Hours: 0,
            generatedAt: demoOverview.refreshedAt,
          },
        }}
      />,
    )

    expect(screen.getByText(/0 open recovery incidents · staged 1,000 \/ terminal prefix 900.*60s normal budget/)).toBeTruthy()
    expect(screen.queryByText(/3 legacy gap signals/)).toBeNull()
  })

  it("uses the 15 minute inbox age budget only during active recovery", () => {
    const durability = {
      environment: "dev" as const,
      checkpoints: [{
        environment: "dev" as const,
        sourceGeneration: "v2-us-west-1",
        sourceHost: "jetstream.us-west.bsky.network",
        streamNSID: "network.bsky.jetstream.subscribeEvents",
        filterFingerprint: "filters-v1",
        cursorKind: "jetstream_v2_seq" as const,
        replayState: "replaying" as const,
        replayBytesDownloaded: 0,
        replayRetryCount: 0,
        replayRangeResumeCount: 0,
        updatedAt: demoOverview.refreshedAt,
      }],
      inbox: { pending: 1, leased: 0, retrying: 0, applied: 0, deadLetters: 0, total: 1, oldestPendingAgeSeconds: 600 },
      incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
      replayBytesRolling24Hours: 0,
      generatedAt: demoOverview.refreshedAt,
    }
    render(<HealthStrip overview={{ ...demoOverview, durability }} />)

    expect(screen.getByText(/900s recovery budget/)).toBeTruthy()
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

    expect(screen.getByText(/jetstream transport heartbeat .* Charybdis freshness healthy/)).toBeTruthy()
    expect(screen.getByText("Good")).toBeTruthy()
  })

  it("uses durable checkpoint freshness for Jetstream V2 inbox authority", () => {
    const services = demoOverview.services.map((service) => ({
      ...service,
      freshness: "healthy" as const,
      dependencyState: service.service === "appview-worker"
        ? { ...service.dependencyState, ingestion_authority: "jetstream_v2_inbox" }
        : service.dependencyState,
    }))
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          services,
          ingestion: undefined,
          evidence: {
            ...demoOverview.evidence,
            ingestion: {
              ...demoOverview.evidence.ingestion,
              accuracy: "exact",
              validUntil: demoOverview.refreshedAt,
            },
          },
          durability: {
            environment: "dev",
            checkpoints: [{
              environment: "dev",
              sourceGeneration: "v2-us-west-1",
              sourceHost: "jetstream.us-west.bsky.network",
              streamNSID: "network.bsky.jetstream.subscribeEvents",
              filterFingerprint: "filters-v1",
              cursorKind: "jetstream_v2_seq",
              replayState: "live",
              replayBytesDownloaded: 0,
              replayRetryCount: 0,
              replayRangeResumeCount: 0,
              intakeHeartbeatAt: demoOverview.refreshedAt,
              updatedAt: demoOverview.refreshedAt,
            }],
            inbox: { pending: 0, leased: 0, retrying: 0, applied: 0, deadLetters: 0, total: 0 },
            incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
            replayBytesRolling24Hours: 0,
            generatedAt: demoOverview.refreshedAt,
          },
        }}
      />,
    )

    expect(screen.getByText("Ingestion Freshness").nextElementSibling?.textContent).toBe("Good")
    expect(screen.getByText(/Jetstream V2 Inbox · authoritative checkpoint .* Charybdis freshness healthy/)).toBeTruthy()
  })

  it("does not treat a projection checkpoint write as V2 intake freshness", () => {
    const services = demoOverview.services.map((service) => ({
      ...service,
      freshness: "healthy" as const,
      dependencyState: service.service === "appview-worker"
        ? {
            ...service.dependencyState,
            ingestion_authority: "jetstream_v2_inbox",
            jetstream_v2_source_generation: "v2-us-west-1",
          }
        : service.dependencyState,
    }))
    render(
      <HealthStrip
        overview={{
          ...demoOverview,
          services,
          ingestion: undefined,
          evidence: {
            ...demoOverview.evidence,
            ingestion: {
              ...demoOverview.evidence.ingestion,
              accuracy: "exact",
              validUntil: demoOverview.refreshedAt,
            },
          },
          durability: {
            environment: "dev",
            checkpoints: [{
              environment: "dev",
              sourceGeneration: "v2-us-west-1",
              sourceHost: "jetstream.us-west.bsky.network",
              streamNSID: "network.bsky.jetstream.subscribeEvents",
              filterFingerprint: "filters-v1",
              cursorKind: "jetstream_v2_seq",
              replayState: "live",
              replayBytesDownloaded: 0,
              replayRetryCount: 0,
              replayRangeResumeCount: 0,
              intakeHeartbeatAt: new Date(
                new Date(demoOverview.refreshedAt).getTime() - 60_000,
              ).toISOString(),
              updatedAt: demoOverview.refreshedAt,
            }],
            inbox: { pending: 0, leased: 0, retrying: 0, applied: 0, deadLetters: 0, total: 0 },
            incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
            replayBytesRolling24Hours: 0,
            generatedAt: demoOverview.refreshedAt,
          },
        }}
      />,
    )

    expect(screen.getByText("Ingestion Freshness").nextElementSibling?.textContent).toBe("Unknown")
    expect(screen.getByText(/authoritative checkpoint 60.0s ago/)).toBeTruthy()
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
