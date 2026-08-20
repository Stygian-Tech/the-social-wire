import Link from "next/link"
import { DataColumnHeaders } from "@/components/operations/data-column-headers"
import { OperationsSection } from "@/components/operations/operations-section"
import { OperationsEmptyState } from "@/components/operations/operations-empty-state"
import { OperatorActionDialog } from "@/components/operations/operator-action-dialog"
import { Badge } from "@/components/ui/badge"
import { buttonVariants } from "@/components/ui/button"
import { Table, TableBody, TableCell, TableHeader, TableRow } from "@/components/ui/table"
import {
  ingestionAuthoritySource,
  isJetstreamV2InboxSource,
  jetstreamStateForOverview,
} from "@/lib/operations-policy"
import { operationsXrpc } from "@/lib/operations-xrpc"
import type { Alert, EnvironmentName, Overview } from "@/lib/operations-types"

const reconnectRules = new Set([
  "jetstream_disconnected",
  "jetstream_connected_idle",
  "jetstream_committed_cursor_stale",
  "jetstream_commit_backlog",
  "jetstream_transport_evidence_missing",
  "jetstream_transport_heartbeat_expired",
])
const activeGapRules = new Set(["active_ingestion_gap", "active_ingestion_incident", "confirmed_ingestion_gap"])

function deliveryLabel(alert: Alert) {
  if (alert.deliveryDeadLetteredAt) return "Dead Letter"
  if (alert.lastDeliveryError)
    return alert.nextDeliveryAt
      ? `Failed · retry ${new Date(alert.nextDeliveryAt).toLocaleString()}`
      : `Failed · ${alert.lastDeliveryError}`
  return `${alert.deliveryAttempts} attempts`
}

function AlertActions({
  alert,
  data,
  environment,
  mutationsEnabled,
}: {
  alert: Alert
  data: Overview
  environment: EnvironmentName
  mutationsEnabled: boolean
}) {
  const reconnectActive = (data.commands ?? []).some(
    (command) => command.action === "reconnect_jetstream" && ["queued", "running"].includes(command.status),
  )
  const lifecycleAction = alert.status === "open" ? "acknowledge" : alert.status === "acknowledged" ? "resolve" : undefined
  const lifecycleLabel = lifecycleAction === "acknowledge" ? "Acknowledge" : "Resolve"
  const versionUnavailable = alert.version === undefined
  const jetstreamState = jetstreamStateForOverview(data)
  const legacyReconnectSupported = !isJetstreamV2InboxSource(ingestionAuthoritySource(data))
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      {reconnectRules.has(alert.rule) && legacyReconnectSupported ? (
        reconnectActive ? (
          <Badge tone="warning">Reconnect In Progress</Badge>
        ) : (
          <OperatorActionDialog
            environment={environment}
            path={operationsXrpc.reconnectIngestion}
            label="Reconnect Jetstream"
            targetLabel={`for alert ${alert.id}`}
            expectedVersion={jetstreamState?.version}
            disabled={!mutationsEnabled || jetstreamState?.version === undefined}
            disabledReason={!mutationsEnabled ? "Operator mutations are disabled" : "Stream version evidence is unavailable"}
          />
        )
      ) : activeGapRules.has(alert.rule) ? (
        <Link href="/gaps" className="ops-touch-link text-primary">Investigate Gaps</Link>
      ) : alert.rule === "backfill_without_progress" || alert.rule === "terminal_backfill_failure" ? (
        <Link href="/backfills" className="ops-touch-link text-primary">Manage Backfills</Link>
      ) : null}
      {alert.lastDeliveryError ? (
        <OperatorActionDialog
          environment={environment}
          path={operationsXrpc.retryAlert}
          subjectId={alert.id}
          label="Retry Delivery"
          targetLabel={`for alert ${alert.id}`}
          expectedVersion={alert.version}
          disabled={!mutationsEnabled || versionUnavailable || !(data.capabilities?.alertDelivery.enabled ?? false)}
          disabledReason={data.capabilities?.alertDelivery.disabledReason ?? (versionUnavailable ? "Alert version evidence is unavailable" : "Alert delivery is disabled")}
        />
      ) : null}
      {lifecycleAction ? (
        <OperatorActionDialog
          environment={environment}
          path={lifecycleAction === "acknowledge" ? operationsXrpc.acknowledgeAlert : operationsXrpc.resolveAlert}
          subjectId={alert.id}
          label={lifecycleLabel}
          targetLabel={`alert ${alert.id}`}
          expectedVersion={alert.version}
          disabled={!mutationsEnabled || versionUnavailable}
          disabledReason={!mutationsEnabled ? "Operator mutations are disabled" : "Alert version evidence is unavailable"}
        />
      ) : (
        <Badge tone="success">Resolved</Badge>
      )}
    </div>
  )
}

function AlertList({ alerts, data, environment, mutationsEnabled, emptyMessage }: { alerts: Alert[]; data: Overview; environment: EnvironmentName; mutationsEnabled: boolean; emptyMessage: string }) {
  if (!alerts.length) return <OperationsEmptyState>{emptyMessage}</OperationsEmptyState>
  return (
    <>
      <div className="grid gap-2 p-3 md:hidden">
        {alerts.map((alert) => (
          <article key={alert.id} className="ops-record-card">
            <header className="flex items-start justify-between gap-3">
              <h3 className="break-all font-mono text-xs font-semibold">{alert.rule}</h3>
              <div className="flex gap-1"><Badge tone={alert.severity === "critical" ? "danger" : "warning"}>{alert.severity}</Badge><Badge>{alert.status}</Badge></div>
            </header>
            <p className="mt-3 text-[10px]">{alert.summary}</p>
            <p className="mt-2 break-all font-mono text-[9px] text-muted-foreground">Condition: {alert.conditionKey}</p>
            <dl className="mt-3 grid grid-cols-2 gap-2 text-[9px]">
              <div><dt className="text-muted-foreground">Opened</dt><dd className="mt-0.5">{new Date(alert.openedAt).toLocaleString()}</dd></div>
              <div><dt className="text-muted-foreground">Delivery</dt><dd className="mt-0.5">{deliveryLabel(alert)}</dd></div>
            </dl>
            <Link href={`/runbooks#${alert.runbookSlug}`} className="ops-touch-link mt-3 text-[10px] text-primary">Open Runbook</Link>
            <div className="mt-3 border-t border-border/45 pt-3"><AlertActions alert={alert} data={data} environment={environment} mutationsEnabled={mutationsEnabled} /></div>
          </article>
        ))}
      </div>
      <div className="hidden md:block">
        <Table>
          <TableHeader><TableRow><DataColumnHeaders labels={["Severity", "Status", "Rule", "Condition Key", "Summary", "Opened", "Delivery", "Runbook", "Legal Actions"]} /></TableRow></TableHeader>
          <TableBody>
            {alerts.map((alert) => (
              <TableRow key={alert.id}>
                <TableCell><Badge tone={alert.severity === "critical" ? "danger" : "warning"}>{alert.severity}</Badge></TableCell>
                <TableCell>{alert.status}</TableCell>
                <TableCell className="font-mono">{alert.rule}</TableCell>
                <TableCell className="font-mono">{alert.conditionKey}</TableCell>
                <TableCell>{alert.summary}</TableCell>
                <TableCell>{new Date(alert.openedAt).toLocaleString()}</TableCell>
                <TableCell className={alert.deliveryDeadLetteredAt || alert.lastDeliveryError ? "text-destructive" : undefined}>{deliveryLabel(alert)}</TableCell>
                <TableCell><Link href={`/runbooks#${alert.runbookSlug}`} className="ops-touch-link text-primary">Open Runbook</Link></TableCell>
                <TableCell><AlertActions alert={alert} data={data} environment={environment} mutationsEnabled={mutationsEnabled} /></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
    </>
  )
}

export function AlertsTable({
  data,
  environment,
  mutationsEnabled = true,
  view = "active",
}: {
  data: Overview
  environment: EnvironmentName
  mutationsEnabled?: boolean
  view?: "active" | "history"
}) {
  const alerts = data.alerts ?? []
  const activeCount = data.counts.unresolvedAlerts
  const emptyMessage =
    view === "active" && activeCount > 0
      ? `${activeCount.toLocaleString()} unresolved alerts are reported, but row evidence is unavailable in this response.`
      : "No alerts in this lifecycle."
  return (
    <div className="grid gap-3">
      <nav aria-label="Alert lifecycle views" className="flex flex-wrap gap-2">
        <Link
          href="/alerts/active"
          aria-current={view === "active" ? "page" : undefined}
          className={buttonVariants({ variant: view === "active" ? "secondary" : "outline", size: "sm" })}
        >
          Active ({activeCount.toLocaleString()})
        </Link>
        <Link
          href="/alerts/history"
          aria-current={view === "history" ? "page" : undefined}
          className={buttonVariants({ variant: view === "history" ? "secondary" : "outline", size: "sm" })}
        >
          History
        </Link>
      </nav>
      <OperationsSection title={view === "history" ? "Resolved Alert History" : "Active Alerts"}>
        <AlertList alerts={alerts} data={data} environment={environment} mutationsEnabled={mutationsEnabled} emptyMessage={emptyMessage} />
      </OperationsSection>
    </div>
  )
}
