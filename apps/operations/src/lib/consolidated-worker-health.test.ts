import { describe, expect, it } from "bun:test"
import { demoOverview } from "@/lib/demo-data"
import { ingestionAuthoritySource, jetstreamV2CheckpointForOverview } from "@/lib/operations-policy"
import { SERVICE_HEALTH_METRIC, serviceHealthEvidence, stableServiceHealthEvidence } from "@/lib/observability-values"
import type { MetricRollup, Overview, ServiceState } from "@/lib/operations-types"
import { serviceHealthRollingTrends } from "@/lib/service-health-trends"

const reference = "2026-09-26T12:05:30Z"
const active = { coordinator_authority: "active", coordinator_role: "indexing.appview-coordinator" }
function service(name: string, dependencyState: Record<string, string> = {}): ServiceState {
  return { ...demoOverview.services[0]!, service: name, instanceId: name, heartbeatAt: reference,
    liveness: "healthy", readiness: "healthy", freshness: "healthy", completeness: "healthy", dependencyState }
}
const projection = () => service("projection-pool-appview", { ingestion_authority: "jetstream_v2_inbox", jetstream_v2_source_generation: "projection-generation" })
const coordinator = () => service("coordinator-appview", active)
function overview(services: ServiceState[]): Overview {
  return { ...demoOverview, refreshedAt: reference, services, ingestion: undefined, metricRollups: [] }
}
function metric(name: string, dimension: string, minute = 4, dimensions: Record<string, string> = {}): MetricRollup {
  return { environment: "dev", metricName: SERVICE_HEALTH_METRIC,
    bucketStart: `2026-09-26T12:0${minute}:00Z`,
    dimensions: { service: name, dimension, state: "healthy", ...dimensions }, sampleCount: 8, valueSum: 8 }
}

describe("consolidated AppView worker coverage", () => {
  it("uses Projection metadata and honors the authoritative ingestion response", () => {
    const state = overview([service("appview-worker", { ingestion_authority: "tap" }), projection(), coordinator()])
    expect(ingestionAuthoritySource(state)).toBe("jetstream_v2_inbox")
    expect(ingestionAuthoritySource({ ...state, ingestion: { ...demoOverview.ingestion!, source: "jetstream" } })).toBe("jetstream")
    expect(ingestionAuthoritySource(overview([service("appview-worker", { ingestion_authority: "tap" }), coordinator()]))).toBeUndefined()
  })

  it("selects the checkpoint advertised by Projection during overlapping deployment", () => {
    const state = overview([projection(), service("appview-worker", { jetstream_v2_source_generation: "legacy" })])
    const base = { environment: "dev" as const, sourceHost: "jetstream.example", streamNSID: "stream", filterFingerprint: "filter", cursorKind: "jetstream_v2_seq" as const, replayState: "live" as const, replayBytesDownloaded: 0, replayRetryCount: 0, replayRangeResumeCount: 0, updatedAt: reference }
    state.durability = { environment: "dev", generatedAt: reference,
      checkpoints: [{ ...base, sourceGeneration: "legacy" }, { ...base, sourceGeneration: "projection-generation" }],
      inbox: { pending: 0, leased: 0, retrying: 0, applied: 0, deadLetters: 0, total: 0 },
      incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 }, replayBytesRolling24Hours: 0 }
    expect(jetstreamV2CheckpointForOverview(state)?.sourceGeneration).toBe("projection-generation")
  })

  it("requires Projection and an authoritative Coordinator for complete coverage", () => {
    for (const dimension of ["liveness", "readiness", "completeness"] as const) {
      expect(serviceHealthEvidence([projection(), coordinator()], dimension, reference, ["appview-worker"]))
        .toEqual({ state: "healthy", healthy: 2, total: 2 })
      expect(serviceHealthEvidence([projection(), service("coordinator-appview")], dimension, reference, ["appview-worker"]).state).toBe("unknown")
      expect(serviceHealthEvidence([projection(), service("coordinator-appview", { ...active, coordinator_role: "wrong-role" })], dimension, reference, ["appview-worker"]).state).toBe("unknown")
    }
    expect(serviceHealthEvidence([projection()], "freshness", reference, ["appview-worker"]).state).toBe("healthy")
  })

  it("does not substitute a fresh legacy worker for stale or missing consolidated roles", () => {
    const stale = { ...projection(), heartbeatAt: "2026-09-26T12:00:00Z" }
    const legacy = service("appview-worker")
    expect(serviceHealthEvidence([stale, coordinator(), legacy], "freshness", reference, ["appview-worker"]).state).toBe("unknown")
    expect(serviceHealthEvidence([projection(), legacy], "completeness", reference, ["appview-worker"]).state).toBe("unknown")
    expect(serviceHealthEvidence([legacy], "completeness", reference, ["appview-worker"]).state).toBe("healthy")
  })

  it("ignores standby replicas only when active Coordinator evidence is present", () => {
    const standby = { ...service("coordinator-appview", { ...active, coordinator_authority: "standby" }), readiness: "unhealthy" as const }
    expect(serviceHealthEvidence([projection(), coordinator(), standby], "readiness", reference, ["appview-worker"]).state).toBe("healthy")
    expect(serviceHealthEvidence([projection(), standby], "readiness", reference, ["appview-worker"]).state).toBe("unknown")
  })

  it("never lets healthy historical samples hide lost current authority", () => {
    const state = overview([projection(), service("coordinator-appview", { ...active, coordinator_authority: "standby" })])
    state.metricRollups = [metric("appview-worker", "completeness"), metric("projection-pool-appview", "completeness"), metric("coordinator-appview", "completeness", 4, active)]
    expect(stableServiceHealthEvidence(state, "completeness", reference, ["appview-worker"]).state).toBe("unknown")
    state.services = [projection(), coordinator()]
    expect(stableServiceHealthEvidence(state, "completeness", reference, ["appview-worker"]).state).toBe("healthy")
    state.metricRollups = [metric("appview-worker", "completeness")]
    expect(stableServiceHealthEvidence(state, "completeness", reference, ["appview-worker"]).state).toBe("unknown")
  })

  it("keeps pre-handoff history and gaps when consolidated roles disappear", () => {
    const samples = [metric("appview-worker", "completeness", 0),
      metric("projection-pool-appview", "completeness", 1), metric("coordinator-appview", "completeness", 1, active),
      metric("projection-pool-appview", "completeness", 2), metric("appview-worker", "completeness", 2),
      metric("projection-pool-appview", "freshness", 2)]
    const points = serviceHealthRollingTrends(samples)
    expect(points[0]?.completeness).toBe(100)
    expect(points[1]?.completeness).toBe(100)
    expect(points[2]?.completeness).toBeNull()
    expect(points[2]?.freshness).toBe(100)
  })

  it("does not infer historical authority from a coordinator name or standby sample", () => {
    for (const dimensions of [{}, { ...active, coordinator_authority: "standby" }]) {
      const points = serviceHealthRollingTrends([metric("projection-pool-appview", "completeness"), metric("coordinator-appview", "completeness", 4, dimensions)])
      expect(points[0]?.completeness).toBeNull()
    }
  })
})
