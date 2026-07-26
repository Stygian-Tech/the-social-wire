import { GapCollectionScope } from "@/components/operations/gaps/gap-collection-scope"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { TableCell, TableRow } from "@/components/ui/table"
import type { Gap } from "@/lib/operations-types"

function GapActions({
  gap,
  onSelect,
  onInvestigate,
  allowBackfill,
  mutationsEnabled,
}: {
  gap: Gap
  onSelect: (gap: Gap) => void
  onInvestigate: (gap: Gap) => void
  allowBackfill: boolean
  mutationsEnabled: boolean
}) {
  const canBackfill = allowBackfill && (gap.status === "confirmed" || gap.status === "verification_required")
  const disabled = !mutationsEnabled || gap.version === undefined
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <Button size="sm" variant="outline" aria-label={`Investigate gap ${gap.id}`} onClick={() => onInvestigate(gap)}>
        Investigate
      </Button>
      {canBackfill ? (
        <Button
          size="sm"
          variant="outline"
          disabled={disabled}
          title={!mutationsEnabled ? "Recovery mutations are disabled" : gap.version === undefined ? "Gap version is unavailable" : undefined}
          aria-label={`Backfill gap ${gap.id}`}
          onClick={() => onSelect(gap)}
        >
          Backfill
        </Button>
      ) : gap.status === "backfill_queued" || gap.status === "backfilling" ? (
        <Badge tone="warning">Recovery {gap.status === "backfill_queued" ? "Queued" : "Running"}</Badge>
      ) : null}
    </div>
  )
}

export function GapRow({
  gap,
  onSelect,
  onInvestigate,
  allowBackfill,
  mutationsEnabled,
}: {
  gap: Gap
  onSelect: (gap: Gap) => void
  onInvestigate: (gap: Gap) => void
  allowBackfill: boolean
  mutationsEnabled: boolean
}) {
  return (
    <TableRow>
      <TableCell>
        <Badge tone={gap.status === "confirmed" ? "danger" : gap.status.includes("backfill") || gap.status === "verification_required" ? "warning" : "neutral"}>
          {gap.status.replaceAll("_", " ")}
        </Badge>
      </TableCell>
      <TableCell className="font-mono">
        {gap.startCursor ?? "—"} ..
        <br />
        {gap.endCursor ?? "—"}
      </TableCell>
      <TableCell>{gap.reason.replaceAll("_", " ")}</TableCell>
      <TableCell>{new Date(gap.detectedAt).toLocaleString()}</TableCell>
      <TableCell><GapCollectionScope collections={gap.collections} /></TableCell>
      <TableCell>
        <GapActions gap={gap} onSelect={onSelect} onInvestigate={onInvestigate} allowBackfill={allowBackfill} mutationsEnabled={mutationsEnabled} />
      </TableCell>
    </TableRow>
  )
}

export function GapCard({
  gap,
  onSelect,
  onInvestigate,
  allowBackfill,
  mutationsEnabled,
}: {
  gap: Gap
  onSelect: (gap: Gap) => void
  onInvestigate: (gap: Gap) => void
  allowBackfill: boolean
  mutationsEnabled: boolean
}) {
  return (
    <article className="rounded-md border bg-background p-3">
      <header className="flex items-start justify-between gap-3">
        <h3 className="break-all font-mono text-xs font-semibold">{gap.id}</h3>
        <Badge tone={gap.status === "confirmed" ? "danger" : gap.status === "resolved" ? "success" : "warning"}>
          {gap.status.replaceAll("_", " ")}
        </Badge>
      </header>
      <dl className="mt-3 grid grid-cols-2 gap-2 text-[10px]">
        <div><dt className="text-muted-foreground">Reason</dt><dd className="mt-0.5">{gap.reason.replaceAll("_", " ")}</dd></div>
        <div><dt className="text-muted-foreground">Detected</dt><dd className="mt-0.5">{new Date(gap.detectedAt).toLocaleString()}</dd></div>
        <div className="col-span-2"><dt className="text-muted-foreground">Cursor Range (μs)</dt><dd className="mt-0.5 break-all font-mono">{gap.startCursor ?? "—"} .. {gap.endCursor ?? "—"}</dd></div>
        <div className="col-span-2"><dt className="text-muted-foreground">Collections</dt><dd className="mt-0.5"><GapCollectionScope collections={gap.collections} /></dd></div>
      </dl>
      <div className="mt-3 border-t pt-3">
        <GapActions gap={gap} onSelect={onSelect} onInvestigate={onInvestigate} allowBackfill={allowBackfill} mutationsEnabled={mutationsEnabled} />
      </div>
    </article>
  )
}
