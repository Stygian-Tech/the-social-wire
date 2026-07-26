import type { EnvironmentName, Overview, Span } from "@/lib/operations-types"

export function jetstreamStateForOverview(overview: Overview) {
  return overview.ingestionSources.find((state) => state.source.toLowerCase() === "jetstream")
    ?? (overview.ingestion?.source.toLowerCase() === "jetstream" ? overview.ingestion : undefined)
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
