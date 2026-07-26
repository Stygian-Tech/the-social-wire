import type { EventStreamState } from "@/lib/use-operations-event-stream"

export const DEFAULT_LIVE_FALLBACK_POLL_MILLISECONDS = 2_500

export function liveRoutePollInterval({
  autoRefresh,
  visible,
  eventStreamState,
  fallbackMilliseconds,
}: {
  autoRefresh: boolean
  visible: boolean
  eventStreamState: EventStreamState
  fallbackMilliseconds: number
}) {
  if (!autoRefresh || !visible || eventStreamState === "live") return false
  return Math.min(DEFAULT_LIVE_FALLBACK_POLL_MILLISECONDS, Math.max(1_000, fallbackMilliseconds))
}
