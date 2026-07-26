"use client"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { AlertTriangle, Play, ShieldAlert } from "lucide-react"
import { useEffect, useMemo, useState } from "react"
import { BackfillCollectionSelector } from "@/components/operations/backfills/backfill-collection-selector"
import { BackfillProgress } from "@/components/operations/backfills/backfill-progress"
import { BackfillReadiness } from "@/components/operations/backfills/backfill-readiness"
import { BackfillSummary } from "@/components/operations/backfills/backfill-summary"
import {
  OperationsRequestError,
  operationsErrorText,
} from "@/components/operations/operations-request-error"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import {
  AlertDialog,
  AlertDialogClose,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { Select } from "@/components/ui/select"
import { Sheet, SheetContent, SheetDescription, SheetFooter, SheetHeader, SheetTitle } from "@/components/ui/sheet"
import { Toast } from "@/components/ui/toast"
import { useOperationsAuth } from "@/lib/auth-context"
import { isBackfillTerminal } from "@/lib/backfill-lifecycle"
import { dryRunBackfill, fetchBackfill, operationsRequest } from "@/lib/operations-api"
import { canQueueBackfill, type BackfillReadinessInput } from "@/lib/operations-policy"
import type {
  Backfill,
  BackfillDryRun,
  EnvironmentName,
  Gap,
  Overview,
  RecoveryModeCapabilities,
} from "@/lib/operations-types"
import { initialBackfillCollections, recoveryCollectionOptions } from "@/lib/backfill-collections"
import { parseAuthorDids } from "@/lib/pds-diagnostics"
import { useDocumentVisibility } from "@/lib/use-document-visibility"

export function BackfillSheet({
  gap,
  environment,
  open,
  mutationsEnabled,
  recoveryModes,
  onOpenChange,
}: {
  gap?: Gap
  environment: EnvironmentName
  open: boolean
  mutationsEnabled: boolean
  recoveryModes?: RecoveryModeCapabilities
  onOpenChange: (open: boolean) => void
}) {
  const { session } = useOperationsAuth()
  const queryClient = useQueryClient()
  const documentVisible = useDocumentVisibility()
  const [auditNote, setAuditNote] = useState("")
  const [reviewed, setReviewed] = useState(false)
  const [productionConfirmation, setProductionConfirmation] = useState("")
  const [sourceMode, setSourceMode] = useState<BackfillDryRun["sourceMode"]>("tap_verified_resync")
  const [authorDidInput, setAuthorDidInput] = useState("")
  const [batchSize, setBatchSize] = useState(1000)
  const [rateLimit, setRateLimit] = useState(500)
  const [maxConcurrency, setMaxConcurrency] = useState(2)
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID())
  const [collections, setCollections] = useState<string[]>(() =>
    initialBackfillCollections(gap?.collections ?? [], "tap_verified_resync"),
  )
  const [createdJobId, setCreatedJobId] = useState<string>()
  const [notification, setNotification] = useState<{ title: string; description: string; tone: "success" | "error" }>()
  const [validationTime, setValidationTime] = useState(() => Date.now())
  const authorDids = useMemo(() => parseAuthorDids(authorDidInput), [authorDidInput])
  const selectedModeCapability =
    sourceMode === "tap_verified_resync"
      ? recoveryModes?.tapVerifiedResync
      : sourceMode === "jetstream_replay"
        ? recoveryModes?.jetstreamReplay
        : recoveryModes?.pdsReconciliation
  const selectedModeEnabled = mutationsEnabled && (selectedModeCapability?.enabled ?? false)
  const supportedCollections = recoveryCollectionOptions(sourceMode)
  const effectiveConcurrency = sourceMode === "pds_reconciliation" ? maxConcurrency : 1
  const boundsValid =
    Number.isSafeInteger(batchSize) &&
    batchSize >= 1 &&
    batchSize <= 10_000 &&
    Number.isSafeInteger(rateLimit) &&
    rateLimit >= 1 &&
    rateLimit <= 5_000 &&
    Number.isSafeInteger(effectiveConcurrency) &&
    effectiveConcurrency >= 1 &&
    effectiveConcurrency <= 16
  const request = useMemo<BackfillDryRun>(
    () => ({
      gapId: gap?.id,
      sourceMode,
      startCursor: gap?.startCursor,
      endCursor: gap?.endCursor,
      collections,
      authorDids: sourceMode === "jetstream_replay" ? [] : authorDids.valid,
      batchSize,
      rateLimit,
      maxConcurrency: effectiveConcurrency,
    }),
    [authorDids.valid, batchSize, collections, effectiveConcurrency, gap, rateLimit, sourceMode],
  )
  const dryRun = useMutation({
    mutationFn: () => dryRunBackfill(session, request),
    onSuccess: () => setIdempotencyKey(crypto.randomUUID()),
  })
  const dryRunIsCurrent = Boolean(
    dryRun.data?.requestFingerprint &&
      dryRun.data.validUntil &&
      new Date(dryRun.data.validUntil).getTime() > validationTime,
  )
  const changeSourceMode = (value: string) => {
    const mode = value as BackfillDryRun["sourceMode"]
    setSourceMode(mode)
    setCollections((current) => current.filter((collection) => recoveryCollectionOptions(mode).includes(collection)))
    dryRun.reset()
    setReviewed(false)
  }
  const changeCollections = (value: string[]) => {
    setCollections(value)
    dryRun.reset()
    setReviewed(false)
  }
  const configurationChanged = () => {
    dryRun.reset()
    setReviewed(false)
  }
  const create = useMutation({
    mutationFn: () => {
      if (!dryRun.data || !dryRunIsCurrent)
        throw new Error("Run a current signed dry run before queueing recovery.")
      return operationsRequest<Backfill>(session, "/v1/operations/backfills", {
        method: "POST",
        body: JSON.stringify({
          dryRun: request,
          expectedEstimate: dryRun.data.estimatedCount,
          requestFingerprint: dryRun.data.requestFingerprint,
          auditNote: auditNote.trim() || undefined,
          environmentConfirmation: productionConfirmation || undefined,
          idempotencyKey,
          expectedGapVersion: gap?.version,
        }),
        headers: { "Idempotency-Key": idempotencyKey },
      })
    },
    onSuccess: (created) => {
      queryClient.setQueryData(["operations-backfill", environment, created.id], created)
      setCreatedJobId(created.id)
      setNotification({
        title: "Backfill Initiated",
        description: `${created.id} was queued successfully. Live progress is now shown in this panel.`,
        tone: "success",
      })
      void queryClient.invalidateQueries({ queryKey: ["operations-overview", environment] })
      void queryClient.invalidateQueries({ queryKey: ["operations-route", environment] })
    },
    onError: (error) =>
      setNotification({
        title: "Backfill Not Initiated",
        description: operationsErrorText(error),
        tone: "error",
      }),
  })
  const job = useQuery({
    queryKey: ["operations-backfill", environment, createdJobId],
    queryFn: () => fetchBackfill(session, createdJobId!),
    enabled: Boolean(createdJobId) && open,
    refetchInterval: (query) =>
      documentVisible && !(query.state.data && isBackfillTerminal(query.state.data.status)) ? 2_000 : false,
  })
  const activeJob = job.data ?? create.data
  useEffect(() => {
    if (!notification) return
    const timer = window.setTimeout(() => setNotification(undefined), 6_000)
    return () => window.clearTimeout(timer)
  }, [notification])
  useEffect(() => {
    if (!open) return
    const timer = window.setInterval(() => setValidationTime(Date.now()), 1_000)
    return () => window.clearInterval(timer)
  }, [open])
  useEffect(() => {
    if (!job.data) return
    queryClient.setQueryData<Overview>(["operations-overview", environment], (overview) => {
      if (!overview) return overview
      const existingBackfills = overview.backfills ?? []
      const index = existingBackfills.findIndex((candidate) => candidate.id === job.data.id)
      const backfills =
        index === -1
          ? [job.data, ...existingBackfills]
          : existingBackfills.map((candidate) => (candidate.id === job.data.id ? job.data : candidate))
      return { ...overview, backfills }
    })
  }, [environment, job.data, queryClient])
  const readinessInput: BackfillReadinessInput = {
    collectionScopeSelected:
      boundsValid && collections.length > 0 &&
      (sourceMode === "jetstream_replay" || (authorDids.valid.length > 0 && authorDids.invalid.length === 0)),
    dryRunComplete: dryRunIsCurrent,
    dryRunConflictFree: Boolean(dryRun.data && dryRun.data.conflicts.length === 0),
    reviewed,
    environment,
    environmentConfirmation: productionConfirmation,
    pending: create.isPending,
  }
  const canRun = selectedModeEnabled && canQueueBackfill(readinessInput)
  return (
    <>
      <Sheet open={open} onOpenChange={onOpenChange}>
        <SheetContent>
          <SheetHeader>
            <SheetTitle className="text-sm font-semibold">
              {activeJob ? `Backfill ${activeJob.id}` : "Backfill Gap"}
            </SheetTitle>
            <SheetDescription className="mt-1 text-[10px] text-muted-foreground">
              {activeJob
                ? "Live recovery progress and resumable checkpoint state."
                : "Dry-run-first recovery with resumable checkpoints."}
            </SheetDescription>
          </SheetHeader>
          {activeJob ? (
            <BackfillProgress job={activeJob} refreshing={job.isFetching} />
          ) : (
            <div className="flex-1 overflow-y-auto overscroll-contain p-4">
              <div className="flex items-center justify-between border-b pb-3 text-xs">
                <span>
                  Gap{" "}
                  <Badge tone="danger" className="ml-1">
                    {gap?.status ?? "Open"}
                  </Badge>
                </span>
                <span className="text-[10px] text-muted-foreground">
                  {gap ? new Date(gap.detectedAt).toLocaleString() : "No gap selected"}
                </span>
              </div>
              <section className="mt-4">
                <p className="text-xs font-semibold">Cursor / Time Range (μs)</p>
                <div className="mt-2 rounded-md border bg-muted/25 p-3 font-mono text-[10px]">
                  <p>
                    {gap?.startCursor ?? "—"} .. {gap?.endCursor ?? "—"}
                  </p>
                  <p className="mt-2 text-muted-foreground">
                    Δ{" "}
                    {gap?.startCursor !== undefined && gap.endCursor !== undefined
                      ? (gap.endCursor - gap.startCursor).toLocaleString()
                      : "—"}{" "}
                    μs
                  </p>
                </div>
              </section>
              <section className="mt-4">
                <div className="flex items-center justify-between">
                  <p className="text-xs font-semibold">Dry-Run Summary</p>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => dryRun.mutate()}
                    disabled={
                      !gap ||
                      collections.length === 0 ||
                      dryRun.isPending ||
                      !selectedModeEnabled ||
                      !boundsValid ||
                      (sourceMode !== "jetstream_replay" &&
                        (authorDids.valid.length === 0 || authorDids.invalid.length > 0))
                    }
                  >
                    {dryRun.isPending ? "Estimating…" : dryRun.data ? "Refresh Estimate" : "Run Dry-Run"}
                  </Button>
                </div>
                <dl className="mt-2 divide-y rounded-md border text-[10px]">
                  <BackfillSummary
                    label={dryRun.data?.estimateKind === "observed" ? "Observed Event Count" : "Modeled Event Estimate"}
                    value={dryRun.data?.estimatedCount.toLocaleString() ?? "Required"}
                  />
                  <BackfillSummary
                    label="Rate-Limit Projection"
                    value={dryRun.data ? `~ ${Math.ceil(dryRun.data.estimatedDurationSeconds / 60)} min` : "—"}
                  />
                  <BackfillSummary
                    label="Estimate Kind"
                    value={dryRun.data ? (dryRun.data.estimateKind === "observed" ? "Observed" : "Modeled") : "—"}
                  />
                  <BackfillSummary
                    label="Methodology"
                    value={dryRun.data?.methodology ?? "—"}
                  />
                  <BackfillSummary
                    label="Confidence"
                    value={dryRun.data?.confidence ?? "—"}
                  />
                  <BackfillSummary
                    label="Uncertainty Range"
                    value={
                      dryRun.data?.uncertainty
                        ? `${dryRun.data.uncertainty.lowerBound.toLocaleString()}–${dryRun.data.uncertainty.upperBound.toLocaleString()}`
                        : "Not Reported"
                    }
                  />
                  <BackfillSummary
                    label="Signed Request Valid Until"
                    value={dryRun.data ? new Date(dryRun.data.validUntil).toLocaleString() : "—"}
                  />
                  <BackfillSummary
                    label="Existing Conflicts"
                    value={dryRun.data ? (dryRun.data.conflicts.length ? String(dryRun.data.conflicts.length) : "None") : "—"}
                  />
                </dl>
                {dryRun.data?.conflicts.length ? (
                  <Alert variant="warning" className="mt-3">
                    <AlertTriangle className="mb-1 size-3.5" />
                    <AlertTitle>Backfill Not Needed or Already Covered</AlertTitle>
                    <AlertDescription>
                      <ul className="grid gap-1">
                        {dryRun.data.conflicts.map((conflict) => (
                          <li key={conflict}>{conflict}</li>
                        ))}
                      </ul>
                    </AlertDescription>
                  </Alert>
                ) : null}
                {dryRun.isError ? (
                  <Alert variant="destructive" className="mt-3">
                    <AlertTitle>Dry Run Failed</AlertTitle>
                    <AlertDescription>
                      <OperationsRequestError error={dryRun.error} />
                    </AlertDescription>
                  </Alert>
                ) : null}
                {dryRun.data && !dryRunIsCurrent ? (
                  <Alert variant="warning" className="mt-3">
                    <AlertTitle>Dry Run Expired</AlertTitle>
                    <AlertDescription>
                      Run the dry run again before queueing recovery; its signed request fingerprint is no longer valid.
                    </AlertDescription>
                  </Alert>
                ) : null}
                {dryRun.data?.unresolvedDeletesWarning ? (
                  <Alert variant="warning" className="mt-3">
                    <AlertTitle>Historical Deletes Are Not Proven</AlertTitle>
                    <AlertDescription>
                      This diagnostic can observe current records but cannot establish historical delete completeness.
                    </AlertDescription>
                  </Alert>
                ) : null}
              </section>
              <section className="mt-4">
                <p className="text-xs font-semibold">Backfill Configuration</p>
                <FieldGroup className="mt-3 grid-cols-[1fr_1.2fr]">
                  <FieldLabel>Source Mode</FieldLabel>
                  <Select
                    ariaLabel="Source Mode"
                    value={sourceMode}
                    onValueChange={changeSourceMode}
                    options={[
                      {
                        value: "tap_verified_resync",
                        label: "Tap Verified Resync",
                        disabled: !(recoveryModes?.tapVerifiedResync.enabled ?? false),
                      },
                      {
                        value: "jetstream_replay",
                        label: "Jetstream Replay",
                        disabled: !(recoveryModes?.jetstreamReplay.enabled ?? false),
                      },
                      {
                        value: "pds_reconciliation",
                        label: "PDS Diagnostic Reconciliation",
                        disabled: !(recoveryModes?.pdsReconciliation.enabled ?? false),
                      },
                    ]}
                  />
                  <FieldLabel>Start Time (μs)</FieldLabel>
                  <Input className="font-mono" value={request.startCursor ?? ""} readOnly />
                  <FieldLabel>End Time (μs)</FieldLabel>
                  <Input className="font-mono" value={request.endCursor ?? ""} readOnly />
                  <FieldLabel>Collection Filters</FieldLabel>
                  <BackfillCollectionSelector
                    value={collections}
                    options={supportedCollections}
                    onValueChange={changeCollections}
                    legacyCollections={gap?.collections}
                  />
                  {sourceMode !== "jetstream_replay" ? (
                    <>
                      <FieldLabel htmlFor="recovery-author-dids">
                        {sourceMode === "tap_verified_resync" ? "Repository DIDs" : "Author DIDs"}
                      </FieldLabel>
                      <div>
                        <Textarea
                          id="recovery-author-dids"
                          value={authorDidInput}
                          onChange={(event) => {
                            setAuthorDidInput(event.target.value)
                            configurationChanged()
                          }}
                          placeholder="did:plc:example (one per line or comma-separated)"
                          className="font-mono"
                        />
                        {authorDids.invalid.length ? (
                          <p role="alert" className="mt-1 text-[9px] text-destructive">
                            Invalid DID scope: {authorDids.invalid.join(", ")}
                          </p>
                        ) : (
                          <p className="mt-1 text-[9px] text-muted-foreground">
                            {authorDids.valid.length} unique author DID{authorDids.valid.length === 1 ? "" : "s"} selected.
                          </p>
                        )}
                      </div>
                    </>
                  ) : null}
                  <FieldLabel>Bounded Batch Size</FieldLabel>
                  <Input
                    type="number"
                    min={1}
                    max={10_000}
                    value={batchSize}
                    onChange={(event) => {
                      setBatchSize(Number(event.target.value))
                      configurationChanged()
                    }}
                  />
                  <FieldLabel>
                    {sourceMode === "pds_reconciliation" ? "PDS Request Rate Limit" : "Source Event Rate Limit"}
                  </FieldLabel>
                  <Input
                    type="number"
                    min={1}
                    max={5_000}
                    value={rateLimit}
                    onChange={(event) => {
                      setRateLimit(Number(event.target.value))
                      configurationChanged()
                    }}
                  />
                  {sourceMode === "pds_reconciliation" ? (
                    <>
                      <FieldLabel>PDS Request Concurrency</FieldLabel>
                      <Input
                        type="number"
                        min={1}
                        max={16}
                        value={request.maxConcurrency}
                        onChange={(event) => {
                          setMaxConcurrency(Number(event.target.value))
                          configurationChanged()
                        }}
                      />
                    </>
                  ) : sourceMode === "jetstream_replay" ? (
                    <>
                      <FieldLabel>Execution Model</FieldLabel>
                      <Input value="Serial · 1 replay worker" readOnly aria-label="Jetstream Replay Execution Model" />
                    </>
                  ) : null}
                  <FieldLabel>Snapshot End Cursor</FieldLabel>
                  <Input className="font-mono" value={dryRun.data?.snapshotEndCursor ?? "Dry-run required"} readOnly />
                </FieldGroup>
                {!boundsValid ? (
                  <p role="alert" className="mt-2 text-[9px] text-destructive">
                    Batch size must be 1–10,000, rate limit 1–5,000, and concurrency 1–16.
                  </p>
                ) : null}
              </section>
              {sourceMode === "tap_verified_resync" ? (
                <Alert variant={selectedModeCapability?.enabled ? "default" : "warning"} className="mt-4">
                  <ShieldAlert className="mb-1 size-3.5" />
                  <AlertTitle>
                    {selectedModeCapability?.enabled ? "Verified Repository Recovery" : "Tap Verified Resync Unavailable"}
                  </AlertTitle>
                  <AlertDescription>
                    {selectedModeCapability?.enabled
                      ? "Only exact-scope, zero-failure, non-truncated Tap recovery can verify completeness and resolve the linked gap."
                      : selectedModeCapability?.disabledReason ??
                        "The capability response did not authorize a safe Tap resync for this environment."}
                  </AlertDescription>
                </Alert>
              ) : sourceMode === "jetstream_replay" ? (
                <Alert variant="warning" className="mt-4">
                  <ShieldAlert className="mb-1 size-3.5" />
                  <AlertTitle>Unverified Supplemental Source</AlertTitle>
                  <AlertDescription>
                    Jetstream replay is bounded and sequential, but cannot prove repository completeness. A successful
                    replay must end in Verification Required and cannot auto-resolve the gap.
                  </AlertDescription>
                </Alert>
              ) : (
                <Alert variant="warning" className="mt-4">
                  <ShieldAlert className="mb-1 size-3.5" />
                  <AlertTitle>DID-Scoped Diagnostic Only</AlertTitle>
                  <AlertDescription>
                    PDS enumeration can compare currently listed records for the selected DIDs. It cannot prove
                    historical deletes and cannot auto-resolve a gap. Truncation and per-author failures must be reviewed.
                  </AlertDescription>
                </Alert>
              )}
              <Field className="mt-4">
                <FieldLabel htmlFor="audit-note">Operator Audit Note (Optional)</FieldLabel>
                <Textarea
                  id="audit-note"
                  value={auditNote}
                  maxLength={280}
                  onChange={(event) => setAuditNote(event.target.value)}
                  placeholder="Add context for this backfill"
                />
                <FieldDescription className="text-right">{auditNote.length} / 280</FieldDescription>
              </Field>
              <label className="mt-4 flex items-start gap-2 text-[10px]">
                <input
                  type="checkbox"
                  className="mt-0.5"
                  checked={reviewed}
                  onChange={(event) => setReviewed(event.target.checked)}
                />
                <span>I have reviewed the dry-run summary, understand the impact, and want to backfill this gap.</span>
              </label>
              {environment === "prod" ? (
                <Field className="mt-3">
                  <FieldLabel htmlFor="production-confirmation">Production Confirmation</FieldLabel>
                  <Input
                    id="production-confirmation"
                    value={productionConfirmation}
                    onChange={(event) => setProductionConfirmation(event.target.value)}
                    placeholder="Type PRODUCTION"
                  />
                  <FieldDescription>A second explicit environment confirmation is required.</FieldDescription>
                </Field>
              ) : null}
              <BackfillReadiness input={readinessInput} />
              {!selectedModeEnabled ? (
                <Alert variant="warning" className="mt-4">
                  <AlertTitle>Recovery Is Read-Only</AlertTitle>
                  <AlertDescription>
                    {process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE === "1"
                      ? "Demo data never sends operator mutations."
                      : selectedModeCapability?.disabledReason ??
                        "The Operations capability contract did not enable this recovery mode."}
                  </AlertDescription>
                </Alert>
              ) : null}
              <Alert variant="warning" className="mt-4">
                <AlertTriangle className="mb-1 size-3.5" />
                <AlertTitle>Backfills can increase load</AlertTitle>
                <AlertDescription>
                  This action cannot be undone, but the job can be paused or cancelled.
                </AlertDescription>
              </Alert>
              {create.isError ? (
                <Alert variant="destructive" className="mt-3">
                  <AlertTitle>Backfill Not Initiated</AlertTitle>
                  <AlertDescription>
                    <OperationsRequestError error={create.error} />
                  </AlertDescription>
                </Alert>
              ) : null}
            </div>
          )}
          {job.isError && activeJob ? (
            <p role="alert" className="border-t px-4 py-2 text-[10px] text-destructive">
              Live updates are temporarily unavailable. Showing the most recent job state.
            </p>
          ) : null}
          <SheetFooter className="flex items-center justify-end gap-3">
            {activeJob ? (
              <Button onClick={() => onOpenChange(false)}>Close</Button>
            ) : (
              <>
                <Button variant="outline" onClick={() => onOpenChange(false)}>
                  Cancel
                </Button>
                <AlertDialog>
                  <AlertDialogTrigger render={<Button variant="destructive" disabled={!canRun} />}>
                    <Play /> Run Backfill
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle className="text-sm font-semibold">Run This Backfill?</AlertDialogTitle>
                      <AlertDialogDescription className="mt-2 text-xs text-muted-foreground">
                        The confirmed dry-run will be queued in{" "}
                        {environment === "prod" ? "Production" : "Development"}. This action is recorded in the
                        immutable audit history.
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogClose render={<Button variant="outline" />}>Cancel</AlertDialogClose>
                      <AlertDialogClose render={<Button variant="destructive" onClick={() => create.mutate()} />}>
                        Queue Backfill
                      </AlertDialogClose>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              </>
            )}
          </SheetFooter>
        </SheetContent>
      </Sheet>
      {notification ? <Toast {...notification} onClose={() => setNotification(undefined)} /> : null}
    </>
  )
}
