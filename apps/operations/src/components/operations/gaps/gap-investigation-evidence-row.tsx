import { ExternalLink } from "lucide-react"
import Link from "next/link"
import {
  formatInvestigationDate,
  titleCaseInvestigationValue,
} from "@/components/operations/gaps/gap-investigation-format"
import { Badge } from "@/components/ui/badge"
import type { GapInvestigationEvidence } from "@/lib/operations-types"

export function GapInvestigationEvidenceRow({
  evidence,
  supportsAssessment,
}: {
  evidence: GapInvestigationEvidence
  supportsAssessment: boolean
}) {
  return (
    <li className="relative pb-3 pl-5 last:pb-0">
      <span
        className={`absolute -left-[5px] top-1.5 size-2 rounded-full border ${supportsAssessment ? "border-primary bg-primary" : "border-muted-foreground/40 bg-background"}`}
      />
      <article
        className={`rounded-md border p-2.5 ${supportsAssessment ? "border-primary/30 bg-primary/[0.03]" : "bg-card"}`}
      >
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="flex items-center gap-1.5">
            <Badge tone={supportsAssessment ? "info" : "neutral"}>{titleCaseInvestigationValue(evidence.kind)}</Badge>
            {supportsAssessment ? (
              <span className="text-[9px] font-medium text-primary">Supports Assessment</span>
            ) : null}
          </div>
          <time className="font-mono text-[9px] text-muted-foreground">
            {formatInvestigationDate(evidence.occurredAt)}
          </time>
        </div>
        <h3 className="mt-2 text-[11px] font-medium">{evidence.title}</h3>
        <p className="mt-0.5 text-[10px] leading-4 text-muted-foreground">{evidence.detail}</p>
        <div className="mt-2 flex flex-wrap items-center gap-1.5">
          <span className="font-mono text-[9px] text-muted-foreground">{evidence.service}</span>
          {evidence.traceId ? (
            <Link
              href={`/traces/${evidence.traceId}`}
              className="ops-touch-link gap-1 text-[9px] text-primary"
            >
              Open Trace <ExternalLink className="size-2.5" />
            </Link>
          ) : null}
        </div>
      </article>
    </li>
  )
}
