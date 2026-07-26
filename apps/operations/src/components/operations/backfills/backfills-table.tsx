import { ExternalLink } from "lucide-react"
import Link from "next/link"
import { BackfillCard, BackfillRow } from "@/components/operations/backfills/backfill-row"
import { DataColumnHeaders } from "@/components/operations/data-column-headers"
import { OperationsSection } from "@/components/operations/operations-section"
import { Table, TableBody, TableHeader, TableRow } from "@/components/ui/table"
import { partitionBackfills } from "@/lib/backfill-lifecycle"
import type { Backfill, EnvironmentName, OperationsCounts } from "@/lib/operations-types"

function BackfillList({
  jobs,
  environment,
  mutationsEnabled,
  emptyMessage,
}: {
  jobs: Backfill[]
  environment: EnvironmentName
  mutationsEnabled: boolean
  emptyMessage: string
}) {
  if (!jobs.length) return <p className="p-6 text-center text-xs text-muted-foreground">{emptyMessage}</p>
  return (
    <>
      <div className="grid gap-2 p-3 md:hidden">
        {jobs.map((job) => (
          <BackfillCard key={job.id} job={job} environment={environment} mutationsEnabled={mutationsEnabled} />
        ))}
      </div>
      <div className="hidden md:block">
        <Table>
          <TableHeader>
            <TableRow>
              <DataColumnHeaders
                labels={["Backfill ID", "Status", "Collection", "Range (μs)", "Progress", "Processed", "Rate", "Checkpoint (μs)", "Legal Actions"]}
              />
            </TableRow>
          </TableHeader>
          <TableBody>
            {jobs.map((job) => (
              <BackfillRow key={job.id} job={job} environment={environment} mutationsEnabled={mutationsEnabled} />
            ))}
          </TableBody>
        </Table>
      </div>
    </>
  )
}

export function BackfillsTable({
  backfills,
  environment,
  expanded,
  mutationsEnabled,
  counts,
  view = "active",
}: {
  backfills: Backfill[]
  environment: EnvironmentName
  expanded?: boolean
  mutationsEnabled: boolean
  counts?: OperationsCounts
  view?: "active" | "needs_attention" | "history"
}) {
  const groups = partitionBackfills(backfills)
  const activeCount = counts?.activeBackfills ?? groups.active.length
  const attentionCount = counts?.attentionBackfills ?? groups.needsAttention.length
  const historyCount = counts?.completedBackfills ?? groups.history.length
  const emptyMessage = (count: number, lifecycle: string, empty: string) =>
    count > 0
      ? `${count.toLocaleString()} ${lifecycle} are reported, but row evidence is unavailable in this response.`
      : empty
  const action = expanded ? undefined : (
    <Link href="/backfills" className="ops-touch-link text-[10px] text-primary">
      View Backfill Lifecycle <ExternalLink className="inline size-3" />
    </Link>
  )

  return (
    <div className="grid gap-3">
      {expanded ? (
        <>
          <nav aria-label="Backfill lifecycle views" className="flex flex-wrap gap-2">
            {[
              ["active", "Active", counts?.activeBackfills],
              ["needs_attention", "Needs Attention", counts?.attentionBackfills],
              ["history", "History", counts?.completedBackfills],
            ].map(([key, label, count]) => (
              <Link
                key={String(key)}
                href={`/backfills/${key}`}
                aria-current={view === key ? "page" : undefined}
                className={`inline-flex min-h-11 items-center rounded-md border px-3 py-2 text-[10px] ${view === key ? "border-primary bg-primary/10 text-primary" : "bg-background"}`}
              >
                {label} {typeof count === "number" ? `(${count.toLocaleString()})` : ""}
              </Link>
            ))}
          </nav>
          {view === "needs_attention" ? (
            <OperationsSection title={`Needs Attention (${attentionCount})`}>
              <BackfillList jobs={groups.needsAttention} environment={environment} mutationsEnabled={mutationsEnabled} emptyMessage={emptyMessage(attentionCount, "failed or cancelled backfills", "No failed or cancelled backfills need review.")} />
            </OperationsSection>
          ) : view === "history" ? (
            <OperationsSection title={`History (${historyCount})`}>
              <BackfillList jobs={groups.history} environment={environment} mutationsEnabled={mutationsEnabled} emptyMessage={emptyMessage(historyCount, "completed backfills", "No completed backfill history.")} />
            </OperationsSection>
          ) : (
            <OperationsSection title={`Active Backfills (${activeCount})`}>
              <BackfillList jobs={groups.active} environment={environment} mutationsEnabled={mutationsEnabled} emptyMessage={emptyMessage(activeCount, "active backfills", "No queued, running, or paused backfills.")} />
            </OperationsSection>
          )}
        </>
      ) : (
        <OperationsSection title={`Active Backfills (${activeCount})`} action={action}>
          <BackfillList jobs={groups.active} environment={environment} mutationsEnabled={mutationsEnabled} emptyMessage={emptyMessage(activeCount, "active backfills", "No queued, running, or paused backfills.")} />
        </OperationsSection>
      )}
    </div>
  )
}
