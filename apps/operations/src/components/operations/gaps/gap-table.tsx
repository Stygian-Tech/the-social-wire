import { DataColumnHeaders } from "@/components/operations/data-column-headers"
import { GapCard, GapRow } from "@/components/operations/gaps/gap-row"
import { Table, TableBody, TableHeader, TableRow } from "@/components/ui/table"
import type { Gap } from "@/lib/operations-types"

export function GapTable({
  gaps,
  onSelect,
  onInvestigate,
  allowBackfill,
  emptyMessage,
  mutationsEnabled,
}: {
  gaps: Gap[]
  onSelect: (gap: Gap) => void
  onInvestigate: (gap: Gap) => void
  allowBackfill: boolean
  emptyMessage: string
  mutationsEnabled: boolean
}) {
  if (!gaps.length) return <p className="p-6 text-center text-xs text-muted-foreground">{emptyMessage}</p>
  return (
    <>
      <div className="grid gap-2 p-3 md:hidden">
        {gaps.map((gap) => (
          <GapCard key={gap.id} gap={gap} onSelect={onSelect} onInvestigate={onInvestigate} allowBackfill={allowBackfill} mutationsEnabled={mutationsEnabled} />
        ))}
      </div>
      <div className="hidden md:block">
        <Table>
          <TableHeader>
            <TableRow>
              <DataColumnHeaders labels={["Status", "Cursor / Time Range (μs)", "Reason", "Detected", "Affected Collections", "Legal Actions"]} />
            </TableRow>
          </TableHeader>
          <TableBody>
            {gaps.map((gap) => (
              <GapRow key={gap.id} gap={gap} onSelect={onSelect} onInvestigate={onInvestigate} allowBackfill={allowBackfill} mutationsEnabled={mutationsEnabled} />
            ))}
          </TableBody>
        </Table>
      </div>
    </>
  )
}
