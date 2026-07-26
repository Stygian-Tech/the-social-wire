import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import type { Overview } from "@/lib/operations-types"

const EVIDENCE_SECTION_ORDER = [
  "overview",
  "services",
  "ingestion",
  "database",
  "metrics",
  "commands",
  "endpoints",
] as const

export function orderedEvidenceEntries(evidence: Overview["evidence"]) {
  const order = new Map(EVIDENCE_SECTION_ORDER.map((section, index) => [section, index]))
  return Object.entries(evidence ?? {}).sort(([left], [right]) => {
    const leftOrder = order.get(left as (typeof EVIDENCE_SECTION_ORDER)[number])
    const rightOrder = order.get(right as (typeof EVIDENCE_SECTION_ORDER)[number])
    if (leftOrder !== undefined || rightOrder !== undefined)
      return (leftOrder ?? Number.MAX_SAFE_INTEGER) - (rightOrder ?? Number.MAX_SAFE_INTEGER)
    return left.localeCompare(right)
  })
}

export function evidenceAgeAtReference(
  baseAgeSeconds: number,
  generatedAt: string,
  referenceTime: string,
) {
  const generatedAtMs = new Date(generatedAt).getTime()
  const referenceMs = new Date(referenceTime).getTime()
  if (!Number.isFinite(generatedAtMs) || !Number.isFinite(referenceMs)) return undefined
  return baseAgeSeconds + Math.max(0, (referenceMs - generatedAtMs) / 1_000)
}

export function EvidenceInventory({ overview, referenceTime = overview.refreshedAt }: { overview: Overview; referenceTime?: string }) {
  const entries = orderedEvidenceEntries(overview.evidence)
  return (
    <OperationsSection
      title="Evidence Inventory"
      description="Independent source, accuracy, coverage, and validity metadata. Unlike pipelines are never blended into one status."
    >
      {entries.length === 0 ? (
        <p className="p-6 text-center text-xs text-muted-foreground">No section-level provenance was reported.</p>
      ) : (
        <div className="grid gap-2 p-3 sm:grid-cols-2 xl:grid-cols-4">
          {entries.map(([section, evidence]) => {
            const age = evidenceAgeAtReference(evidence.ageSeconds, evidence.generatedAt, referenceTime)
            const validUntil = new Date(evidence.validUntil).getTime()
            const reference = new Date(referenceTime).getTime()
            const current = Number.isFinite(validUntil) && Number.isFinite(reference) && validUntil >= reference
            return (
              <article key={section} className="rounded-md border bg-background p-3">
                <header className="flex items-start justify-between gap-2">
                  <h3 className="break-all font-mono text-[10px] font-semibold">{section}</h3>
                  <Badge tone={evidence.accuracy === "exact" ? "success" : evidence.accuracy === "unavailable" ? "danger" : "warning"}>
                    {evidence.accuracy}
                  </Badge>
                </header>
                <dl className="mt-3 grid gap-1.5 text-[9px]">
                  <div><dt className="text-muted-foreground">Source</dt><dd className="mt-0.5 break-all">{evidence.source}</dd></div>
                  <div><dt className="text-muted-foreground">Evidence Age</dt><dd className="mt-0.5">{age === undefined ? "Unknown" : `${Math.round(age)}s`}</dd></div>
                  <div><dt className="text-muted-foreground">Current Status</dt><dd className="mt-0.5">{current ? "Current" : "Unknown · Expired"}</dd></div>
                  <div><dt className="text-muted-foreground">Coverage</dt><dd className="mt-0.5">{evidence.coverage === undefined ? "Not reported" : `${Math.round(evidence.coverage * 100)}%`}</dd></div>
                  <div><dt className="text-muted-foreground">Indexed Through</dt><dd className="mt-0.5 break-all font-mono">{evidence.indexedThrough ?? "Not reported"}</dd></div>
                </dl>
                {evidence.degradedReason ? <p role="alert" className="mt-3 text-[9px] text-warning">{evidence.degradedReason}</p> : null}
              </article>
            )
          })}
        </div>
      )}
    </OperationsSection>
  )
}
