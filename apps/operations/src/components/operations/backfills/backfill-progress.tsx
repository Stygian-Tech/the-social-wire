import { RefreshCw } from "lucide-react"
import { BackfillStatusIndicator } from "@/components/operations/backfills/backfill-status-indicator"
import { BackfillDetail } from "@/components/operations/backfills/backfill-detail"
import { BackfillFailureReason } from "@/components/operations/backfills/backfill-failure-reason"
import { BackfillMetric } from "@/components/operations/backfills/backfill-metric"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Progress } from "@/components/ui/progress"
import { isBackfillTerminal } from "@/lib/backfill-lifecycle"
import { backfillProgressEvidence, backfillRateLimitLabel } from "@/lib/backfill-progress"
import type { Backfill } from "@/lib/operations-types"

export { isBackfillTerminal } from "@/lib/backfill-lifecycle"

export function BackfillProgress({ job, refreshing }: { job: Backfill; refreshing: boolean }) {
  const progress = backfillProgressEvidence(job)
  const progressLabel =
    progress.percentOfEstimate === null
      ? "Not Measurable"
      : progress.percentOfEstimate > 0 && progress.percentOfEstimate < 1
        ? "<1% of estimate"
        : `${Math.round(progress.percentOfEstimate)}% of estimate`
  const active = !isBackfillTerminal(job.status)
  const waitingForWorker = job.status === "queued"
  const completedEstimateMismatch =
    job.status === "completed" &&
    progress.observedCount !== null &&
    progress.estimatedCount !== null &&
    progress.observedCount !== progress.estimatedCount
  return (
    <div className="flex-1 overflow-y-auto overscroll-contain p-4">
      <div aria-live="polite" className="rounded-md border bg-muted/20 p-3">
        <div className="flex items-center justify-between gap-3">
          <div>
            <p className="text-[10px] text-muted-foreground">Current Status</p>
            <div className="mt-1">
              <BackfillStatusIndicator status={job.status} />
            </div>
          </div>
          <div className="text-right text-[9px] text-muted-foreground">
            <p className="flex items-center justify-end gap-1">
              {active ? (
                <span className={refreshing ? "motion-safe:animate-spin" : undefined}>
                  <RefreshCw className="size-3" />
                </span>
              ) : null}
              {active ? "Live Updates Every 2 Seconds" : "Final Status"}
            </p>
            <p className="mt-1">Updated {new Date(job.updatedAt).toLocaleString()}</p>
          </div>
        </div>
        <div className="mt-4 flex items-end justify-between">
          <span className="font-mono text-xl font-semibold">{progressLabel}</span>
          <span className="font-mono text-[10px] text-muted-foreground">
            {progress.observedCount?.toLocaleString() ?? "Invalid"} observed / ~
            {progress.estimatedCount?.toLocaleString() ?? "Invalid"} estimated
          </span>
        </div>
        <Progress
          value={progress.percentOfEstimate === null ? null : progress.boundedPercent}
          ariaLabel={`Backfill ${job.id} progress`}
          ariaValueText={progressLabel}
          className="mt-2 h-2"
        />
      </div>

      {!progress.valid ? (
        <Alert variant="destructive" className="mt-4">
          <AlertTitle>Invalid Progress Telemetry</AlertTitle>
          <AlertDescription>
            The service returned a negative, fractional, or unsafe count. Progress is withheld instead of displaying a
            fabricated percentage.
          </AlertDescription>
        </Alert>
      ) : null}

      {completedEstimateMismatch ? (
        <Alert variant="warning" className="mt-4">
          <AlertTitle>Run Finished; Estimate Did Not Match</AlertTitle>
          <AlertDescription>
            The worker finished the bounded scan after observing {progress.observedCount!.toLocaleString()} matching
            records. The dry-run estimate was ~{progress.estimatedCount!.toLocaleString()}. Completion describes the
            scan state, not fulfillment of the estimate.
          </AlertDescription>
        </Alert>
      ) : null}

      {waitingForWorker ? (
        <Alert variant="warning" className="mt-4">
          <AlertTitle>Waiting for Worker</AlertTitle>
          <AlertDescription>
            This job is queued but has not been claimed. Check the AppView Worker and its Operations database
            configuration if this state persists.
          </AlertDescription>
        </Alert>
      ) : null}

      {job.status === "failed" ? (
        <Alert variant="destructive" className="mt-4">
          <AlertTitle>Backfill Failed</AlertTitle>
          <AlertDescription>
            <BackfillFailureReason reason={job.failureReason ?? "No failure category was recorded"} />
          </AlertDescription>
        </Alert>
      ) : null}

      {job.sourceMode === "pds_reconciliation" ? (
        <Alert variant="warning" className="mt-4">
          <AlertTitle>PDS Diagnostic Limitation</AlertTitle>
          <AlertDescription>
            Results cover currently enumerable records for {job.authorDids.length} scoped author DID
            {job.authorDids.length === 1 ? "" : "s"}. Historical deletes cannot be proven.
          </AlertDescription>
        </Alert>
      ) : null}

      {job.verificationStatus === "required" || job.verificationStatus === "failed" ? (
        <Alert variant="warning" className="mt-4">
          <AlertTitle>Verification Required</AlertTitle>
          <AlertDescription>
            This run cannot resolve its linked gap automatically. Review exact scope, failures, truncation, and an
            authoritative Tap resync before resolution.
            {job.verificationReason ? ` Reason: ${job.verificationReason}.` : ""}
          </AlertDescription>
        </Alert>
      ) : null}

      {job.scopeTruncated ? (
        <Alert variant="warning" className="mt-4">
          <AlertTitle>Recovery Scope Was Truncated</AlertTitle>
          <AlertDescription>
            This job did not inspect its entire requested scope and cannot establish completeness.
          </AlertDescription>
        </Alert>
      ) : null}

      <section className="mt-4">
        <h3 className="text-xs font-semibold">Backfill Progress</h3>
        <dl className="mt-2 grid grid-cols-2 gap-px overflow-hidden rounded-md border bg-border text-[10px]">
          <BackfillMetric label="Processed" value={job.processedCount.toLocaleString()} />
          <BackfillMetric
            label="Failed"
            value={job.failedCount.toLocaleString()}
            tone={job.failedCount > 0 ? "danger" : undefined}
          />
          <BackfillMetric label="Reconciled" value={job.reconciledCount.toLocaleString()} />
          <BackfillMetric label="Configured Rate Limit" value={backfillRateLimitLabel(job)} />
        </dl>
      </section>

      {job.authorResults?.length ? (
        <section className="mt-4">
          <h3 className="text-xs font-semibold">Per-Author Diagnostic Results</h3>
          <div className="mt-2 grid gap-2">
            {job.authorResults.map((result) => (
              <article key={`${result.did}-${result.collection}`} className="rounded-md border p-2 text-[10px]">
                <p className="break-all font-mono font-medium">{result.did}</p>
                <p className="mt-1 break-all font-mono text-muted-foreground">{result.collection}</p>
                <p className="mt-2">
                  {result.discoveredCount.toLocaleString()} discovered · {result.processedCount.toLocaleString()} processed ·{" "}
                  {result.failedCount.toLocaleString()} failed · {result.status}
                </p>
                <p className="mt-1 text-muted-foreground">
                  {result.capped ? "scope cap reached" : result.truncated ? "truncated response" : "complete response"}
                </p>
                {result.error ? <p role="alert" className="mt-1 text-destructive">{result.error}</p> : null}
              </article>
            ))}
          </div>
        </section>
      ) : null}

      <section className="mt-4">
        <h3 className="text-xs font-semibold">Checkpoint</h3>
        <dl className="mt-2 divide-y rounded-md border text-[10px]">
          <BackfillDetail label="Cursor" value={job.checkpointCursor?.toLocaleString() ?? "Waiting for worker"} mono />
          <BackfillDetail label="Worker" value={job.leaseOwner ?? "Not claimed yet"} mono />
          <BackfillDetail
            label="Lease Expires"
            value={job.leaseExpiresAt ? new Date(job.leaseExpiresAt).toLocaleString() : "—"}
          />
          <BackfillDetail label="Verification Status" value={job.verificationStatus.replaceAll("_", " ")} />
          <BackfillDetail label="Validation Watermark" value={job.validationWatermark ?? "Not recorded"} mono />
        </dl>
      </section>

      <section className="mt-4">
        <h3 className="text-xs font-semibold">Queued Request</h3>
        <dl className="mt-2 divide-y rounded-md border text-[10px]">
          <BackfillDetail label="Job ID" value={job.id} mono />
          <BackfillDetail
            label="Source Mode"
            value={
              job.sourceMode === "tap_verified_resync"
                ? "Tap verified resync"
                : job.sourceMode === "jetstream_replay"
                  ? "Jetstream replay · unverified"
                  : "PDS diagnostic reconciliation"
            }
          />
          <BackfillDetail label="Range (μs)" value={`${job.startCursor ?? "—"} .. ${job.endCursor ?? "—"}`} mono />
          <BackfillDetail label="Collections" value={job.collections.join(", ") || "PDS reconciliation"} mono />
          {job.authorDids.length ? <BackfillDetail label="Author DIDs" value={job.authorDids.join(", ")} mono /> : null}
          <BackfillDetail label="Requested" value={new Date(job.createdAt).toLocaleString()} />
        </dl>
      </section>
    </div>
  )
}
