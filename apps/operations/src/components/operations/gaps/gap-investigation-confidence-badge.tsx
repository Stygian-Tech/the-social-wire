import { Badge } from "@/components/ui/badge"
import { titleCaseInvestigationValue } from "@/components/operations/gaps/gap-investigation-format"
import type { GapCauseAssessment } from "@/lib/operations-types"

export function GapInvestigationConfidenceBadge({ assessment }: { assessment: GapCauseAssessment }) {
  const tone =
    assessment.confidence === "high"
      ? "success"
      : assessment.confidence === "medium"
        ? "warning"
        : assessment.confidence === "low"
          ? "info"
          : "neutral"
  return (
    <Badge tone={tone}>
      {assessment.confidence === "insufficient"
        ? "Insufficient Evidence"
        : `${titleCaseInvestigationValue(assessment.confidence)} Confidence`}
    </Badge>
  )
}
