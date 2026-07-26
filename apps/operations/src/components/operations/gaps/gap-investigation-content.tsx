import { AlertTriangle, CheckCircle2 } from "lucide-react"
import { GapInvestigationConfidenceBadge } from "@/components/operations/gaps/gap-investigation-confidence-badge"
import { GapInvestigationEvidenceRow } from "@/components/operations/gaps/gap-investigation-evidence-row"
import { formatInvestigationDate } from "@/components/operations/gaps/gap-investigation-format"
import { Badge } from "@/components/ui/badge"
import type { GapInvestigation } from "@/lib/operations-types"

export function GapInvestigationContent({ investigation }: { investigation: GapInvestigation }) {
  const evidenceIds = new Set(investigation.assessment.evidenceIds)
  return (
    <div className="grid gap-4">
      <section aria-labelledby="cause-assessment-title" className="rounded-md border bg-card p-3">
        <div className="flex flex-wrap items-center gap-2">
          <h2 id="cause-assessment-title" className="text-xs font-semibold">
            Likely Trigger
          </h2>
          <GapInvestigationConfidenceBadge assessment={investigation.assessment} />
        </div>
        <p className="mt-2 text-sm font-medium">{investigation.assessment.title}</p>
        <p className="mt-1 text-[11px] leading-5 text-muted-foreground">{investigation.assessment.summary}</p>
      </section>
      <section aria-labelledby="evidence-title">
        <div className="mb-2 flex items-end justify-between gap-3">
          <div>
            <h2 id="evidence-title" className="text-xs font-semibold">
              Evidence Timeline
            </h2>
            <p className="mt-0.5 text-[9px] text-muted-foreground">
              {formatInvestigationDate(investigation.windowStart)} – {formatInvestigationDate(investigation.windowEnd)}
            </p>
          </div>
          <Badge>{investigation.evidence.length} Signals</Badge>
        </div>
        <ol className="relative ml-2 border-l">
          {investigation.evidence.map((item) => (
            <GapInvestigationEvidenceRow key={item.id} evidence={item} supportsAssessment={evidenceIds.has(item.id)} />
          ))}
        </ol>
      </section>
      <section
        aria-labelledby="limitations-title"
        className="rounded-md border border-warning/30 bg-warning-surface p-3"
      >
        <div className="flex items-center gap-2 text-warning">
          <AlertTriangle className="size-3.5" />
          <h2 id="limitations-title" className="text-xs font-semibold">
            What This Does Not Prove
          </h2>
        </div>
        <ul className="mt-2 grid gap-1.5 text-[10px] leading-4 text-warning/90">
          {investigation.assessment.limitations.map((limitation) => (
            <li key={limitation}>• {limitation}</li>
          ))}
        </ul>
      </section>
      <section aria-labelledby="next-checks-title">
        <h2 id="next-checks-title" className="text-xs font-semibold">
          Next Checks
        </h2>
        <ul className="mt-2 grid gap-2">
          {investigation.recommendedActions.map((action) => (
            <li key={action} className="flex gap-2 text-[10px] leading-4 text-muted-foreground">
              <CheckCircle2 className="mt-0.5 size-3 shrink-0 text-primary" />
              <span>{action}</span>
            </li>
          ))}
        </ul>
      </section>
    </div>
  )
}
