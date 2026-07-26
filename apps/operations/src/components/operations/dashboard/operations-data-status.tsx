"use client"

import { Badge } from "@/components/ui/badge"
import { dashboardFreshness } from "@/lib/dashboard-freshness"
import type { Overview } from "@/lib/operations-types"
import type { EventStreamState } from "@/lib/use-operations-event-stream"

export function OperationsDataStatus({
  overview,
  autoRefresh,
  requestFailed,
  detailFallback,
  eventStreamState,
  now,
}: {
  overview?: Overview
  autoRefresh: boolean
  requestFailed: boolean
  detailFallback: boolean
  eventStreamState: EventStreamState
  now: number
}) {
  const freshness = dashboardFreshness({ overview, autoRefresh, requestFailed, detailFallback, now })
  const tone =
    freshness.state === "live"
      ? "success"
      : freshness.state === "delayed" || freshness.state === "paused"
        ? "warning"
        : freshness.state === "partial"
          ? "info"
          : "danger"

  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 border-b bg-muted/30 px-3 py-2 text-[10px] sm:px-4" role="status">
      <Badge tone={tone}>{freshness.state}</Badge>
      <span>{freshness.reason}</span>
      <span className="ml-auto text-muted-foreground">
        Age {freshness.ageSeconds === null ? "unknown" : `${Math.round(freshness.ageSeconds)}s`}
        {freshness.evidence ? ` · ${freshness.evidence.source} · ${freshness.evidence.accuracy}` : ""}
      </span>
      {eventStreamState !== "disabled" ? (
        <span className="text-muted-foreground">
          Event updates: {eventStreamState === "reconnecting" ? "polling fallback" : eventStreamState}
        </span>
      ) : null}
    </div>
  )
}
