import type { EvidenceEnvelope, Overview } from "@/lib/operations-types"

export type DashboardFreshnessState = "live" | "delayed" | "stale" | "partial" | "offline" | "paused"

export type DashboardFreshness = {
  state: DashboardFreshnessState
  ageSeconds: number | null
  evidence?: EvidenceEnvelope
  reason: string
}

export function dashboardFreshness({
  overview,
  autoRefresh,
  requestFailed,
  detailFallback,
  now = Date.now(),
}: {
  overview?: Overview
  autoRefresh: boolean
  requestFailed: boolean
  detailFallback: boolean
  now?: number
}): DashboardFreshness {
  if (!overview) return { state: "offline", ageSeconds: null, reason: "No successful Operations response is available." }

  const evidenceEntries = Object.values(overview.evidence)
  const observedEvidence = evidenceEntries
    .map((evidence) => ({ evidence, ageSeconds: evidenceAge(evidence, now) }))
    .filter((item): item is { evidence: EvidenceEnvelope; ageSeconds: number } => item.ageSeconds !== null)
  const oldest = observedEvidence.reduce<(typeof observedEvidence)[number] | undefined>(
    (current, item) => !current || item.ageSeconds > current.ageSeconds ? item : current,
    undefined,
  )
  const fallbackGeneratedAt = new Date(overview.refreshedAt).getTime()
  const ageSeconds = oldest?.ageSeconds ?? (
    Number.isFinite(fallbackGeneratedAt) ? Math.max(0, (now - fallbackGeneratedAt) / 1_000) : null
  )
  const expiredEvidence = evidenceEntries.find((evidence) => {
    const validUntil = new Date(evidence.validUntil).getTime()
    return !Number.isFinite(validUntil) || validUntil < now
  })
  const degradedEvidence = evidenceEntries.find((evidence) =>
    evidence.accuracy === "unavailable" ||
    Boolean(evidence.degradedReason) ||
    (evidence.coverage !== undefined && evidence.coverage < 1),
  )
  const evidence = degradedEvidence ?? expiredEvidence ?? oldest?.evidence

  if (requestFailed)
    return {
      state: "offline",
      ageSeconds,
      evidence,
      reason: "Refresh failed. Last-known-good evidence remains visible.",
    }
  if (
    detailFallback || degradedEvidence
  )
    return {
      state: "partial",
      ageSeconds,
      evidence,
      reason: detailFallback
        ? "The dedicated route failed; this view is using the last overview snapshot."
        : degradedEvidence?.degradedReason ?? "One or more evidence sources are incomplete.",
    }
  if (!autoRefresh)
    return {
      state: "paused",
      ageSeconds,
      evidence,
      reason: "Automatic refresh is paused. Values will age until Refresh Now is used.",
    }
  if (expiredEvidence || ageSeconds === null || ageSeconds > 75)
    return {
      state: "stale",
      ageSeconds,
      evidence,
      reason: expiredEvidence ? "At least one evidence source has expired." : "Evidence is older than the 75-second freshness budget.",
    }
  if (ageSeconds > 5)
    return {
      state: "delayed",
      ageSeconds,
      evidence,
      reason: "Evidence is inside the historical freshness budget but no longer live.",
    }
  return { state: "live", ageSeconds, evidence, reason: "Evidence is inside the five-second live-state budget." }
}

function evidenceAge(evidence: EvidenceEnvelope, now: number) {
  const generatedAt = new Date(evidence.generatedAt).getTime()
  if (!Number.isFinite(generatedAt)) return null
  return evidence.ageSeconds + Math.max(0, (now - generatedAt) / 1_000)
}
