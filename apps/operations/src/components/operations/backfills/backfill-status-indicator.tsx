import { Badge } from "@/components/ui/badge"
import type { Backfill } from "@/lib/operations-types"

export function BackfillStatusIndicator({ status }: { status: Backfill["status"] }) {
  const active = status === "running"
  const tone =
    status === "completed"
      ? "success"
      : status === "failed" || status === "cancelled"
        ? "danger"
        : status === "queued" || active
          ? "warning"
          : "neutral"
  const label = status.charAt(0).toUpperCase() + status.slice(1)

  return (
    <Badge tone={tone}>
      <span className="relative mr-1.5 flex size-2" aria-hidden="true">
        {active ? (
          <span className="absolute inline-flex size-full rounded-full bg-current opacity-50 motion-safe:animate-ping" />
        ) : null}
        <span className="relative inline-flex size-2 rounded-full bg-current" />
      </span>
      {label}
    </Badge>
  )
}
