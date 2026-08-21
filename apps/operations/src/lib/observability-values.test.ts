import { describe, expect, it } from "bun:test"
import {
  effectiveConnectionState,
  elapsedSeconds,
  overallSystemHealth,
  overviewIngestionConnectionState,
  rollingServiceHealthEvidence,
  SERVICE_HEALTH_METRIC,
  serviceHealthEvidence,
  stableServiceHealthEvidence,
} from "@/lib/observability-values"
import { demoOverview } from "@/lib/demo-data"
import type { Health, MetricRollup } from "@/lib/operations-types"

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

  it("uses a five minute rolling average instead of one degraded refresh", () => {
    const reference = demoOverview.refreshedAt
    const rollups = requiredHealthRollups(reference, "liveness", "healthy", 40)
    rollups.push(healthRollup(reference, "gateway", "liveness", "degraded", 1))

    const evidence = rollingServiceHealthEvidence(rollups, "liveness", reference)

    expect(evidence?.state).toBe("healthy")
    expect(evidence?.healthy).toBe(4)
    expect(evidence?.sampleCount).toBe(161)
    expect(evidence?.windowMinutes).toBe(5)
  })

  it("reports sustained degradation once it occupies at least one fifth of the window", () => {
    const reference = demoOverview.refreshedAt
    const rollups = requiredHealthRollups(reference, "readiness", "healthy", 32)
    rollups.push(healthRollup(reference, "appview", "readiness", "degraded", 8))

    expect(rollingServiceHealthEvidence(rollups, "readiness", reference)?.state).toBe("degraded")
  })

  it("fails closed when rolling samples are missing for a required service", () => {
    const reference = demoOverview.refreshedAt
    const rollups = requiredHealthRollups(reference, "liveness", "healthy", 40)
      .filter((rollup) => rollup.dimensions.service !== "operations")

    expect(rollingServiceHealthEvidence(rollups, "liveness", reference)?.state).toBe("unknown")
  })

  it("stabilizes current degraded state when the completed rolling window is healthy", () => {
    const reference = demoOverview.refreshedAt
    const overview = {
      ...demoOverview,
      services: allHealthyServices().map((service) =>
        service.service === "gateway" ? { ...service, liveness: "degraded" as const } : service,
      ),
      metricRollups: requiredHealthRollups(reference, "liveness", "healthy", 40),
    }

    expect(serviceHealthEvidence(overview.services, "liveness", reference).state).toBe("degraded")
    expect(stableServiceHealthEvidence(overview, "liveness", reference).state).toBe("healthy")
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

  it("uses durable incidents instead of legacy gap signal totals when durability is available", () => {
    const services = allHealthyServices()
    expect(overallSystemHealth({
      ...demoOverview,
      services,
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 19_711, unresolvedAlerts: 0 },
      durability: {
        environment: "dev",
        checkpoints: [],
        inbox: { pending: 0, leased: 0, retrying: 0, applied: 0, deadLetters: 0, total: 0 },
        incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 1, ignored: 0 },
        replayBytesRolling24Hours: 0,
        generatedAt: demoOverview.refreshedAt,
      },
    })).toBe("healthy")
  })

  it("uses current durable checkpoint evidence for Jetstream V2 inbox authority health", () => {
    const services = allHealthyServices().map((service) => service.service === "appview-worker"
      ? { ...service, dependencyState: { ...service.dependencyState, ingestion_authority: "jetstream_v2_inbox" } }
      : service)
    expect(overallSystemHealth({
      ...demoOverview,
      services,
      ingestion: undefined,
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 },
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
    })).toBe("healthy")
  })

  it("treats a completed bounded snapshot as healthy terminal evidence", () => {
    const services = allHealthyServices().map((service) => service.service === "appview-worker"
      ? { ...service, dependencyState: { ...service.dependencyState, ingestion_authority: "jetstream_v2_inbox" } }
      : service)
    const overview = {
      ...demoOverview,
      services,
      ingestion: undefined,
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 },
      evidence: {
        ...demoOverview.evidence,
        ingestion: {
          ...demoOverview.evidence.ingestion,
          source: "appview_jetstream_checkpoints",
          accuracy: "exact" as const,
          validUntil: "2100-01-01T00:00:00.000Z",
        },
      },
      durability: {
        environment: "dev" as const,
        checkpoints: [{
          environment: "dev" as const,
          sourceGeneration: "v2-us-west-1",
          sourceHost: "jetstream.us-west.bsky.network",
          streamNSID: "network.bsky.jetstream.subscribeEvents",
          filterFingerprint: "filters-v1",
          cursorKind: "jetstream_v2_seq" as const,
          replayState: "snapshot_complete" as const,
          replayAfterSequence: 100,
          replayBeforeSequence: 200,
          replaySealedSequence: 200,
          replayBytesDownloaded: 1_024,
          replayRetryCount: 0,
          replayRangeResumeCount: 0,
          updatedAt: new Date(
            new Date(demoOverview.refreshedAt).getTime() - 3_600_000,
          ).toISOString(),
        }],
        inbox: { pending: 0, leased: 0, retrying: 0, applied: 100, deadLetters: 0, total: 100 },
        incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
        replayBytesRolling24Hours: 1_024,
        generatedAt: demoOverview.refreshedAt,
      },
    }

    expect(overviewIngestionConnectionState(overview)).toBe("connected")
    expect(overallSystemHealth(overview)).toBe("healthy")
    const synthesized = {
      ...overview,
      ingestion: {
        ...demoOverview.ingestion!,
        source: "jetstream_v2_inbox",
        connectionState: "connected" as const,
        transportHeartbeatAt: undefined,
      },
    }
    expect(overviewIngestionConnectionState(synthesized)).toBe("connected")
    expect(overallSystemHealth(synthesized)).toBe("healthy")
  })

  it("prefers a synthesized disconnected V2 state over fresh checkpoint fallback", () => {
    const services = allHealthyServices()
    const lastDisconnectAt = new Date(new Date(demoOverview.refreshedAt).getTime() - 120_000).toISOString()
    const overview = {
      ...demoOverview,
      services,
      ingestion: {
        ...demoOverview.ingestion!,
        source: "jetstream_v2_inbox",
        connectionState: "disconnected" as const,
        lastDisconnectAt,
      },
      alerts: [],
      counts: { ...demoOverview.counts, activeGaps: 0, unresolvedAlerts: 0 },
      evidence: {
        ...demoOverview.evidence,
        ingestion: {
          ...demoOverview.evidence.ingestion,
          source: "appview_jetstream_checkpoints",
          accuracy: "exact" as const,
          validUntil: demoOverview.refreshedAt,
        },
      },
      durability: {
        environment: "dev" as const,
        checkpoints: [{
          environment: "dev" as const,
          sourceGeneration: "v2-us-west-1",
          sourceHost: "jetstream.us-west.bsky.network",
          streamNSID: "network.bsky.jetstream.subscribeEvents",
          filterFingerprint: "filters-v1",
          cursorKind: "jetstream_v2_seq" as const,
          replayState: "failed" as const,
          replayBytesDownloaded: 0,
          replayRetryCount: 1,
          replayRangeResumeCount: 0,
          updatedAt: demoOverview.refreshedAt,
        }],
        inbox: { pending: 0, leased: 0, retrying: 0, applied: 0, deadLetters: 0, total: 0 },
        incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
        replayBytesRolling24Hours: 0,
        generatedAt: demoOverview.refreshedAt,
      },
    }

    expect(overviewIngestionConnectionState(overview)).toBe("disconnected")
    expect(overallSystemHealth(overview)).toBe("unhealthy")
  })

  it("uses the normal 60 second and recovery 15 minute inbox age budgets", () => {
    const services = allHealthyServices()
    const baseDurability = {
      environment: "dev" as const,
      checkpoints: [{
        environment: "dev" as const,
        sourceGeneration: "v2-us-west-1",
        sourceHost: "jetstream.us-west.bsky.network",
        streamNSID: "network.bsky.jetstream.subscribeEvents",
        filterFingerprint: "filters-v1",
        cursorKind: "jetstream_v2_seq" as const,
        replayState: "live" as const,
        replayBytesDownloaded: 0,
        replayRetryCount: 0,
        replayRangeResumeCount: 0,
        updatedAt: demoOverview.refreshedAt,
      }],
      inbox: { pending: 1, leased: 0, retrying: 0, applied: 0, deadLetters: 0, total: 1, oldestPendingAgeSeconds: 61 },
      incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
      replayBytesRolling24Hours: 0,
      generatedAt: demoOverview.refreshedAt,
    }
    const base = { ...demoOverview, services, alerts: [], counts: { ...demoOverview.counts, unresolvedAlerts: 0 } }
    expect(overallSystemHealth({ ...base, durability: baseDurability })).toBe("degraded")
    expect(overallSystemHealth({
      ...base,
      durability: {
        ...baseDurability,
        checkpoints: [{ ...baseDurability.checkpoints[0]!, replayState: "replaying" }],
      },
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

function healthRollup(
  reference: string,
  service: string,
  dimension: string,
  state: Health,
  count: number,
): MetricRollup {
  const referenceMs = new Date(reference).getTime()
  return {
    environment: "dev",
    bucketStart: new Date(Math.floor(referenceMs / 60_000) * 60_000 - 60_000).toISOString(),
    metricName: SERVICE_HEALTH_METRIC,
    dimensions: { service, dimension, state },
    sampleCount: count,
    valueSum: count,
    valueMin: 1,
    valueMax: 1,
  }
}

function requiredHealthRollups(
  reference: string,
  dimension: string,
  state: Health,
  count: number,
) {
  return ["gateway", "appview", "appview-worker", "operations"].map((service) =>
    healthRollup(reference, service, dimension, state, count),
  )
}
