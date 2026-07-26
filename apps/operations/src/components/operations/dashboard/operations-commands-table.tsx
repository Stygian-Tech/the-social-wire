import { DataColumnHeaders } from "@/components/operations/data-column-headers"
import { OperationsSection } from "@/components/operations/operations-section"
import { Badge } from "@/components/ui/badge"
import { Table, TableBody, TableCell, TableHeader, TableRow } from "@/components/ui/table"
import type { OperationsCommand } from "@/lib/operations-types"

function commandTone(status: OperationsCommand["status"]) {
  if (status === "completed") return "success" as const
  if (status === "failed") return "danger" as const
  if (status === "running") return "warning" as const
  return "neutral" as const
}

export function OperationsCommandsTable({ commands }: { commands: OperationsCommand[] }) {
  return (
    <OperationsSection
      title="Operator Command History"
      description="Durable command lifecycle records from the environment-scoped Operations database."
    >
      {commands.length === 0 ? (
        <p className="p-6 text-center text-xs text-muted-foreground">No operator commands were reported.</p>
      ) : (
        <>
          <div className="grid gap-2 p-3 md:hidden">
            {commands.map((command) => (
              <article key={command.id} className="rounded-md border bg-background p-3">
                <header className="flex items-start justify-between gap-3">
                  <h3 className="break-all font-mono text-xs font-semibold">{command.action}</h3>
                  <Badge tone={commandTone(command.status)}>{command.status}</Badge>
                </header>
                <dl className="mt-3 grid grid-cols-2 gap-2 text-[9px]">
                  <div><dt className="text-muted-foreground">Requested By</dt><dd className="mt-0.5 break-all font-mono">{command.requestedByDid}</dd></div>
                  <div><dt className="text-muted-foreground">Updated</dt><dd className="mt-0.5">{new Date(command.updatedAt).toLocaleString()}</dd></div>
                  <div><dt className="text-muted-foreground">Claimed By</dt><dd className="mt-0.5 break-all font-mono">{command.claimedBy ?? "—"}</dd></div>
                  <div><dt className="text-muted-foreground">Version</dt><dd className="mt-0.5 font-mono">{command.version}</dd></div>
                </dl>
                {command.failureReason ? <p role="alert" className="mt-3 text-[10px] text-destructive">{command.failureReason}</p> : null}
              </article>
            ))}
          </div>
          <div className="hidden md:block">
            <Table>
              <TableHeader>
                <TableRow>
                  <DataColumnHeaders labels={["Command ID", "Operation", "Status", "Requested By", "Claimed By", "Updated", "Version", "Failure Reason"]} />
                </TableRow>
              </TableHeader>
              <TableBody>
                {commands.map((command) => (
                  <TableRow key={command.id}>
                    <TableCell className="font-mono">{command.id}</TableCell>
                    <TableCell className="font-mono">{command.action}</TableCell>
                    <TableCell><Badge tone={commandTone(command.status)}>{command.status}</Badge></TableCell>
                    <TableCell className="font-mono">{command.requestedByDid}</TableCell>
                    <TableCell className="font-mono">{command.claimedBy ?? "—"}</TableCell>
                    <TableCell>{new Date(command.updatedAt).toLocaleString()}</TableCell>
                    <TableCell className="font-mono">{command.version}</TableCell>
                    <TableCell className={command.failureReason ? "text-destructive" : undefined}>{command.failureReason ?? "—"}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </>
      )}
    </OperationsSection>
  )
}
