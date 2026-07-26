import { ExternalLink } from "lucide-react"
import Link from "next/link"
import { GapTable } from "@/components/operations/gaps/gap-table"
import { OperationsSection } from "@/components/operations/operations-section"
import { partitionGapsByBackfillCompletion } from "@/lib/gap-sections"
import type { Backfill, Gap, OperationsCounts } from "@/lib/operations-types"

export function GapsTable({
  gaps,
  backfills,
  onSelect,
  onInvestigate,
  expanded = false,
  mutationsEnabled = true,
  counts,
  view = "active",
}: {
  gaps: Gap[]
  backfills: Backfill[]
  onSelect: (gap: Gap) => void
  onInvestigate: (gap: Gap) => void
  expanded?: boolean
  mutationsEnabled?: boolean
  counts?: OperationsCounts
  view?: "active" | "history"
}) {
  const { activeGaps, backfilledGaps, inactiveGaps } = partitionGapsByBackfillCompletion(gaps, backfills)
  const activeGapCount = counts?.activeGaps ?? activeGaps.length
  const activeEmptyMessage =
    activeGapCount > 0
      ? `${activeGapCount.toLocaleString()} active gaps are reported, but row evidence is unavailable in this response.`
      : "No active gaps."
  const action = expanded ? undefined : (
    <Link href="/gaps" className="ops-touch-link text-[10px] text-primary">
      View All Gaps <ExternalLink className="inline size-3" />
    </Link>
  )

  return (
    <div className="grid gap-3">
      {expanded ? (
        <>
          <nav aria-label="Gap lifecycle views" className="flex flex-wrap gap-2">
            <Link
              href="/gaps/active"
              aria-current={view === "active" ? "page" : undefined}
              className={`inline-flex min-h-11 items-center rounded-md border px-3 py-2 text-[10px] ${view === "active" ? "border-primary bg-primary/10 text-primary" : "bg-background"}`}
            >
              Active ({activeGapCount})
            </Link>
            <Link
              href="/gaps/history"
              aria-current={view === "history" ? "page" : undefined}
              className={`inline-flex min-h-11 items-center rounded-md border px-3 py-2 text-[10px] ${view === "history" ? "border-primary bg-primary/10 text-primary" : "bg-background"}`}
            >
              History
            </Link>
          </nav>
          {view === "history" ? (
            <OperationsSection title={`Resolved / Ignored Gap History (${backfilledGaps.length + inactiveGaps.length})`}>
              <GapTable
                gaps={[...backfilledGaps, ...inactiveGaps]}
                onSelect={onSelect}
                onInvestigate={onInvestigate}
                allowBackfill={false}
                emptyMessage="No resolved or ignored gap history."
                mutationsEnabled={mutationsEnabled}
              />
            </OperationsSection>
          ) : (
            <OperationsSection title={`Active Gaps (${activeGapCount})`}>
              <GapTable
                gaps={activeGaps}
                onSelect={onSelect}
                onInvestigate={onInvestigate}
                allowBackfill
                emptyMessage={activeEmptyMessage}
                mutationsEnabled={mutationsEnabled}
              />
            </OperationsSection>
          )}
        </>
      ) : (
        <OperationsSection title={`Active Gaps (${activeGapCount})`} action={action}>
            <GapTable
              gaps={activeGaps}
              onSelect={onSelect}
              onInvestigate={onInvestigate}
              allowBackfill
              emptyMessage={activeEmptyMessage}
              mutationsEnabled={mutationsEnabled}
            />
        </OperationsSection>
      )}
    </div>
  )
}
