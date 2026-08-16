import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import type { IngestionDurability } from "@/lib/operations-types"

function formatBytes(value: number) {
  if (value < 1_024) return `${value} B`
  if (value < 1_048_576) return `${(value / 1_024).toFixed(1)} KiB`
  if (value < 1_073_741_824) return `${(value / 1_048_576).toFixed(1)} MiB`
  return `${(value / 1_073_741_824).toFixed(2)} GiB`
}

function formatTimestamp(value?: string) {
  if (!value) return "—"
  const date = new Date(value)
  return Number.isFinite(date.getTime()) ? date.toLocaleString() : "Invalid timestamp"
}

export function DurableIngestionStatus({ durability }: { durability?: IngestionDurability }) {
  if (!durability) {
    return (
      <OperationsSection title="Durable Jetstream Recovery">
        <p className="p-3 text-[10px] text-muted-foreground">
          Durable V2 checkpoint and inbox evidence is unavailable. Legacy gap rows remain historical signals, not event-loss counts.
        </p>
      </OperationsSection>
    )
  }
  const checkpoint = durability.checkpoints[0]
  const activeIncidents =
    durability.incidents.open + durability.incidents.recovering + durability.incidents.verificationRequired
  const healthy = activeIncidents === 0 && durability.inbox.deadLetters === 0
  const metrics = [
    ["Source Generation", checkpoint?.sourceGeneration ?? "—"],
    ["Cursor Kind", checkpoint?.cursorKind ?? "—"],
    ["Replay State", checkpoint?.replayState ?? "—"],
    ["Last Staged Sequence", checkpoint?.lastStagedSequence?.toLocaleString() ?? "—"],
    ["Applied Terminal Prefix", checkpoint?.lastAppliedSequence?.toLocaleString() ?? "—"],
    ["Pending / Leased / Retry", `${durability.inbox.pending} / ${durability.inbox.leased} / ${durability.inbox.retrying}`],
    ["Oldest Pending", durability.inbox.oldestPendingAgeSeconds === undefined ? "—" : `${durability.inbox.oldestPendingAgeSeconds.toFixed(1)}s`],
    ["Unresolved Dead Letters", durability.inbox.deadLetters.toLocaleString()],
    ["Open Recovery Incidents", activeIncidents.toLocaleString()],
    ["Replay Usage (Rolling 24h)", formatBytes(durability.replayBytesRolling24Hours)],
    ["Replay Range Resumes", checkpoint?.replayRangeResumeCount.toLocaleString() ?? "—"],
    ["Last Replay Progress", formatTimestamp(checkpoint?.replayLastProgressAt)],
  ]
  return (
    <OperationsSection
      title={
        <span className="flex items-center gap-2">
          Durable Jetstream Recovery <Badge tone={healthy ? "success" : "warning"}>{healthy ? "Healthy" : "Attention"}</Badge>
        </span>
      }
    >
      <div className="grid grid-cols-2 divide-x divide-y sm:grid-cols-3 xl:grid-cols-6">
        {metrics.map(([label, value]) => (
          <div key={label} className="min-w-0 p-3">
            <p className="text-[9px] text-muted-foreground">{label}</p>
            <p className="mt-1 truncate font-mono text-[10px]">{value}</p>
          </div>
        ))}
      </div>
      <p className="border-t px-3 py-2 text-[10px] text-muted-foreground">
        Sequence values are ordered cursors, not contiguous event counters. Staged and terminal-prefix watermarks are shown independently; their numeric difference is never treated as missing events.
      </p>
    </OperationsSection>
  )
}
