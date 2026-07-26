import { BackfillFailureReason } from "@/components/operations/backfills/backfill-failure-reason"
import { BackfillStatusIndicator } from "@/components/operations/backfills/backfill-status-indicator"
import { OperatorActionDialog } from "@/components/operations/operator-action-dialog"
import { Progress } from "@/components/ui/progress"
import { TableCell, TableRow } from "@/components/ui/table"
import { allowedBackfillActions } from "@/lib/backfill-lifecycle"
import { backfillProgressEvidence, backfillRateLimitLabel } from "@/lib/backfill-progress"
import type { Backfill, EnvironmentName } from "@/lib/operations-types"

function jobProgress(job: Backfill) {
  const progress = backfillProgressEvidence(job)
  return {
    ...progress,
    label: progress.percentOfEstimate === null ? "Not measurable" : `${Math.round(progress.percentOfEstimate)}% est.`,
  }
}

export function BackfillActions({
  job,
  environment,
  mutationsEnabled = true,
}: {
  job: Backfill
  environment: EnvironmentName
  mutationsEnabled?: boolean
}) {
  const actions = allowedBackfillActions(job.status)
  const disabled = !mutationsEnabled || job.version === undefined
  const disabledReason = !mutationsEnabled
    ? "Recovery mutations are disabled for this environment"
    : "Version evidence is unavailable; refresh before acting"

  if (!actions.length) return <span className="text-[10px] text-muted-foreground">No legal actions</span>
  return (
    <div className="flex flex-wrap gap-1.5">
      {actions.map((action) => (
        <OperatorActionDialog
          key={action}
          environment={environment}
          path={`/v1/operations/backfills/${encodeURIComponent(job.id)}/${action}`}
          label={action === "pause" ? "Pause" : action === "resume" ? "Resume" : "Cancel"}
          targetLabel={`backfill ${job.id}`}
          expectedVersion={job.version}
          disabled={disabled}
          disabledReason={disabledReason}
          destructive={action === "cancel"}
        />
      ))}
    </div>
  )
}

export function BackfillRow({
  job,
  environment,
  mutationsEnabled = true,
}: {
  job: Backfill
  environment: EnvironmentName
  mutationsEnabled?: boolean
}) {
  const progress = jobProgress(job)
  return (
    <TableRow>
      <TableCell className="font-mono">{job.id}</TableCell>
      <TableCell>
        <BackfillStatusIndicator status={job.status} />
        <BackfillFailureReason reason={job.failureReason} className="mt-1 max-w-48 text-[9px] text-destructive" />
      </TableCell>
      <TableCell className="font-mono">{job.collections[0] ?? "PDS diagnostic"}</TableCell>
      <TableCell className="font-mono">
        {job.startCursor ?? "—"} ..
        <br />
        {job.endCursor ?? "—"}
      </TableCell>
      <TableCell>
        <span className="font-mono">{progress.label}</span>
        <Progress
          value={progress.percentOfEstimate === null ? null : progress.boundedPercent}
          ariaLabel={`Backfill ${job.id} progress`}
          ariaValueText={progress.label}
          className="mt-1 w-24"
        />
      </TableCell>
      <TableCell className="font-mono">{job.processedCount.toLocaleString()}</TableCell>
      <TableCell>{backfillRateLimitLabel(job)}</TableCell>
      <TableCell className="font-mono">{job.checkpointCursor ?? "—"}</TableCell>
      <TableCell>
        <BackfillActions job={job} environment={environment} mutationsEnabled={mutationsEnabled} />
      </TableCell>
    </TableRow>
  )
}

export function BackfillCard({
  job,
  environment,
  mutationsEnabled,
}: {
  job: Backfill
  environment: EnvironmentName
  mutationsEnabled: boolean
}) {
  const progress = jobProgress(job)
  return (
    <article className="rounded-md border bg-background p-3">
      <header className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="break-all font-mono text-xs font-semibold">{job.id}</h3>
          <p className="mt-1 break-all font-mono text-[9px] text-muted-foreground">
            {job.collections.join(", ") || "PDS diagnostic"}
          </p>
        </div>
        <BackfillStatusIndicator status={job.status} />
      </header>
      <Progress
        value={progress.percentOfEstimate === null ? null : progress.boundedPercent}
        ariaLabel={`Backfill ${job.id} progress`}
        ariaValueText={progress.label}
        className="mt-3"
      />
      <dl className="mt-3 grid grid-cols-2 gap-2 text-[10px]">
        <div><dt className="text-muted-foreground">Progress</dt><dd className="mt-0.5 font-mono">{progress.label}</dd></div>
        <div><dt className="text-muted-foreground">Processed</dt><dd className="mt-0.5 font-mono">{job.processedCount.toLocaleString()}</dd></div>
        <div><dt className="text-muted-foreground">Checkpoint</dt><dd className="mt-0.5 break-all font-mono">{job.checkpointCursor ?? "—"}</dd></div>
        <div><dt className="text-muted-foreground">Updated</dt><dd className="mt-0.5">{new Date(job.updatedAt).toLocaleString()}</dd></div>
      </dl>
      <BackfillFailureReason reason={job.failureReason} className="mt-3 text-[10px] text-destructive" />
      <div className="mt-3 border-t pt-3">
        <BackfillActions job={job} environment={environment} mutationsEnabled={mutationsEnabled} />
      </div>
    </article>
  )
}
