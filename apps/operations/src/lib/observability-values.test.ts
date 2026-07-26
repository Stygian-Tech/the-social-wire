import { describe, expect, it } from "bun:test"
import {
  effectiveConnectionState,
  elapsedSeconds,
  overallSystemHealth,
  serviceHealthEvidence,
} from "@/lib/observability-values"
import { demoOverview } from "@/lib/demo-data"

describe("observability values", () => {
  it("derives health from every reporting service instead of a fixed label", () => {
    const evidence = serviceHealthEvidence(demoOverview.services, "freshness")

    expect(evidence.state).toBe("degraded")
    expect(evidence.healthy).toBe(3)
    expect(evidence.total).toBe(4)
    expect(overallSystemHealth(demoOverview)).toBe("unhealthy")
  })

  it("returns unknown when no service reports a dimension", () => {
    expect(serviceHealthEvidence([], "liveness").state).toBe("unknown")
  })

  it("does not let missing evidence erase a known unhealthy or degraded service", () => {
    const gateway = { ...demoOverview.services[0]!, liveness: "unhealthy" as const }
    expect(serviceHealthEvidence([gateway], "liveness").state).toBe("unhealthy")
    expect(serviceHealthEvidence([{ ...gateway, liveness: "degraded" as const }], "liveness").state).toBe("degraded")
  })

  it("does not let an unknown replica erase a known unhealthy logical-service instance", () => {
    const gateway = demoOverview.services[0]!
    expect(serviceHealthEvidence([
      { ...gateway, instanceId: "unknown-replica", liveness: "unknown" as const },
      { ...gateway, instanceId: "unhealthy-replica", liveness: "unhealthy" as const },
    ], "liveness", demoOverview.refreshedAt, ["gateway"]).state).toBe("unhealthy")
  })

  it("withholds invalid or reversed timestamps", () => {
    expect(elapsedSeconds("2026-07-20T20:00:00.000Z", "2026-07-20T20:00:05.000Z")).toBe(5)
    expect(elapsedSeconds("invalid", "2026-07-20T20:00:05.000Z")).toBeNull()
    expect(elapsedSeconds("2026-07-20T20:00:05.000Z", "2026-07-20T20:00:00.000Z")).toBeNull()
  })

  it("uses a reconnecting grace period before reporting a sustained disconnect", () => {
    const referenceTime = "2026-07-23T05:02:00.000Z"
    expect(effectiveConnectionState({
      connectionState: "disconnected",
      transportHeartbeatAt: "2026-07-23T05:01:40.000Z",
      lastDisconnectedAt: "2026-07-23T05:01:30.000Z",
      referenceTime,
    })).toBe("reconnecting")
    expect(effectiveConnectionState({
      connectionState: "disconnected",
      transportHeartbeatAt: "2026-07-23T04:59:00.000Z",
      lastDisconnectedAt: "2026-07-23T04:59:00.000Z",
      referenceTime,
    })).toBe("disconnected")
  })

  it("does not invent a disconnect when transition evidence is missing", () => {
    expect(effectiveConnectionState({
      connectionState: "disconnected",
      referenceTime: "2026-07-23T05:02:00.000Z",
    })).toBe("unknown")
  })

  it("degrades rather than failing global health during the reconnecting grace period", () => {
    const services = allHealthyServices()
    const reference = demoOverview.refreshedAt
    expect(overallSystemHealth({
      ...demoOverview,
      services,
      ingestion: {
        ...demoOverview.ingestion!,
        connectionState: "disconnected",
        lastDisconnectAt: reference,
      },
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 },
    }, reference)).toBe("degraded")
  })

  it("ages the overall system state to unknown against current time", () => {
    const reference = new Date(new Date(demoOverview.refreshedAt).getTime() + 60_000).toISOString()
    expect(overallSystemHealth({ ...demoOverview, alerts: [], counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 } }, reference)).toBe("unknown")
  })

  it("does not infer a connected transport from a fresh generic stream heartbeat", () => {
    const services = allHealthyServices()
    expect(overallSystemHealth({
      ...demoOverview,
      services,
      ingestion: { ...demoOverview.ingestion!, transportHeartbeatAt: undefined, heartbeatAt: demoOverview.refreshedAt },
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 },
    })).toBe("unknown")
  })

  it("requires every logical service before reporting global health", () => {
    const services = allHealthyServices().filter((service) => service.service !== "appview-worker")
    expect(overallSystemHealth({
      ...demoOverview,
      services,
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 },
    })).toBe("unknown")
  })

  it("ignores stale superseded replicas when a fresh replica reports for the logical service", () => {
    const services = allHealthyServices()
    const staleGateway = {
      ...services[0]!,
      instanceId: "retired-gateway",
      liveness: "unhealthy" as const,
      readiness: "unhealthy" as const,
      freshness: "unhealthy" as const,
      completeness: "unhealthy" as const,
      heartbeatAt: new Date(new Date(demoOverview.refreshedAt).getTime() - 86_400_000).toISOString(),
    }
    expect(overallSystemHealth({
      ...demoOverview,
      services: [...services, staleGateway],
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 },
    })).toBe("healthy")
  })

  it("uses the projection worker rather than unrelated service completeness for global health", () => {
    const services = allHealthyServices().map((service) => ({
      ...service,
      completeness: service.service === "appview-worker" ? "healthy" as const : "unknown" as const,
    }))
    expect(overallSystemHealth({
      ...demoOverview,
      services,
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 },
    })).toBe("healthy")
  })
})

function allHealthyServices() {
  return demoOverview.services.map((service) => ({
    ...service,
    liveness: "healthy" as const,
    readiness: "healthy" as const,
    freshness: "healthy" as const,
    completeness: "healthy" as const,
  }))
}
