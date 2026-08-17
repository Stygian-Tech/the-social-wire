import type {
  BackfillDryRun,
  EnvironmentName,
  Overview,
  RecoveryModeCapabilities,
  Span,
} from "@/lib/operations-types"

const LEGACY_JETSTREAM_SOURCE = "jetstream"
export const JETSTREAM_V2_INBOX_SOURCE = "jetstream_v2_inbox"

function normalizedSource(source?: string) {
  return source?.trim().toLowerCase()
}

export function isJetstreamV2InboxSource(source?: string) {
  return normalizedSource(source) === JETSTREAM_V2_INBOX_SOURCE
}

export function ingestionSourceLabel(source: string) {
  if (isJetstreamV2InboxSource(source)) return "Jetstream V2 Inbox · authoritative"
  if (normalizedSource(source) === LEGACY_JETSTREAM_SOURCE) return "Jetstream · unverified supplemental"
  return source
}

function currentIngestionWorker(overview: Overview) {
  return overview.services
    .filter((service) => service.service === "appview-worker")
    .sort((left, right) => Date.parse(right.heartbeatAt) - Date.parse(left.heartbeatAt))[0]
}

export function ingestionAuthoritySource(overview: Overview) {
  if (overview.ingestion?.source) return normalizedSource(overview.ingestion.source)

  const worker = currentIngestionWorker(overview)
  const advertisedSource = normalizedSource(worker?.dependencyState.ingestion_authority)
  return advertisedSource === LEGACY_JETSTREAM_SOURCE ||
    advertisedSource === "tap" ||
    advertisedSource === JETSTREAM_V2_INBOX_SOURCE
    ? advertisedSource
    : undefined
}

export function jetstreamV2CheckpointForOverview(overview: Overview) {
  const checkpoints = overview.durability?.checkpoints.filter(
    (checkpoint) => checkpoint.cursorKind === "jetstream_v2_seq",
  ) ?? []
  const advertisedGeneration = currentIngestionWorker(overview)
    ?.dependencyState.jetstream_v2_source_generation
  if (advertisedGeneration) {
    return checkpoints.find((checkpoint) => checkpoint.sourceGeneration === advertisedGeneration)
  }
  return checkpoints.length === 1 ? checkpoints[0] : undefined
}

/**
 * Picks a recovery source mode the Operations service currently enables.
 *
 * `tap_verified_resync` is reported disabled unconditionally while pinned Tap has no safe resync
 * API, so it can never be the opening selection: it would leave both the dry-run and queue actions
 * disabled with no configuration the operator could change to recover.
 */
export function preferredRecoveryMode(
  recoveryModes?: RecoveryModeCapabilities,
): BackfillDryRun["sourceMode"] | undefined {
  if (!recoveryModes) return undefined
  if (recoveryModes.jetstreamReplay?.enabled) return "jetstream_replay"
  if (recoveryModes.pdsReconciliation?.enabled) return "pds_reconciliation"
  if (recoveryModes.tapVerifiedResync?.enabled) return "tap_verified_resync"
  return undefined
}

export function jetstreamStateForOverview(overview: Overview) {
  if (isJetstreamV2InboxSource(ingestionAuthoritySource(overview))) return undefined
  return overview.ingestionSources.find((state) => normalizedSource(state.source) === LEGACY_JETSTREAM_SOURCE)
    ?? (normalizedSource(overview.ingestion?.source) === LEGACY_JETSTREAM_SOURCE ? overview.ingestion : undefined)
}

export function productionConfirmationMatches(environment: EnvironmentName, value: string) {
  return environment !== "prod" || value === "PRODUCTION"
}

export type BackfillReadinessInput = {
  collectionScopeSelected: boolean
  dryRunComplete: boolean
  dryRunConflictFree: boolean
  reviewed: boolean
  environment: EnvironmentName
  environmentConfirmation: string
  pending: boolean
}

export function backfillReadiness(input: BackfillReadinessInput) {
  return [
    { id: "collection-scope", label: "At least one collection selected", complete: input.collectionScopeSelected },
    { id: "dry-run", label: "Dry-run completed for the current configuration", complete: input.dryRunComplete },
    { id: "conflicts", label: "Dry-run found no existing recovery or completed range", complete: input.dryRunConflictFree },
    { id: "reviewed", label: "Impact review acknowledged", complete: input.reviewed },
    ...(input.environment === "prod"
      ? [
          {
            id: "production-confirmation",
            label: "Production confirmation exactly matches PRODUCTION",
            complete: productionConfirmationMatches(input.environment, input.environmentConfirmation),
          },
        ]
      : []),
  ]
}

export function canQueueBackfill(input: BackfillReadinessInput) {
  return !input.pending && backfillReadiness(input).every((requirement) => requirement.complete)
}

export function filterTraces(spans: Span[], query: string) {
  const normalized = query.trim().toLowerCase()
  if (!normalized) return spans
  return spans.filter((span) =>
    [span.traceId, span.service, span.name, ...Object.values(span.attributes)].some((value) =>
      value.toLowerCase().includes(normalized),
    ),
  )
}
