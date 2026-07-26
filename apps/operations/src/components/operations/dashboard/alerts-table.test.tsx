import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { AlertsTable } from "@/components/operations/dashboard/alerts-table"
import { OperationsAuthProvider } from "@/lib/auth-context"
import { demoOverview } from "@/lib/demo-data"
import type { Alert } from "@/lib/operations-types"

afterEach(cleanup)
process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE = "1"

const baseAlert: Alert = {
  id: "alert-current-rule",
  environment: "dev",
  rule: "active_ingestion_gap",
  conditionKey: "gap:active",
  severity: "critical",
  status: "open",
  summary: "An active ingestion gap requires attention",
  evidence: { gap_id: "gap-1" },
  runbookSlug: "confirming-and-scoping-a-gap",
  openedAt: "2026-07-22T12:00:00.000Z",
  updatedAt: "2026-07-22T12:00:00.000Z",
  deliveryAttempts: 0,
  version: 1,
}

function renderAlerts(alert: Alert, data: typeof demoOverview = demoOverview) {
  const queryClient = new QueryClient()
  render(
    <QueryClientProvider client={queryClient}>
      <OperationsAuthProvider>
        <AlertsTable
          data={{ ...data, alerts: [alert] }}
          environment="dev"
          mutationsEnabled
        />
      </OperationsAuthProvider>
    </QueryClientProvider>,
  )
}

describe("AlertsTable actions", () => {
  it("maps the current active-gap alert rule to investigation", () => {
    renderAlerts(baseAlert)

    expect(screen.getAllByRole("link", { name: "Investigate Gaps" })[0]?.getAttribute("href")).toBe("/gaps")
  })

  for (const rule of ["jetstream_transport_evidence_missing", "jetstream_transport_heartbeat_expired"]) {
    it(`maps ${rule} to guarded reconnect`, () => {
      renderAlerts({ ...baseAlert, id: `alert-${rule}`, rule })

      expect(
        screen.getAllByRole("button", { name: `Reconnect Jetstream for alert alert-${rule}` }).length,
      ).toBeGreaterThan(0)
    })
  }

  it("uses supplemental Jetstream version evidence when Tap is authoritative", () => {
    const jetstream = { ...demoOverview.ingestion!, source: "jetstream", version: 7 }
    const tap = { ...demoOverview.ingestion!, source: "tap", version: undefined as unknown as number }
    renderAlerts(
      { ...baseAlert, id: "alert-jetstream", rule: "jetstream_disconnected" },
      { ...demoOverview, ingestion: tap, ingestionSources: [tap, jetstream] },
    )

    expect(screen.getAllByRole("button", { name: "Reconnect Jetstream for alert alert-jetstream" })[0]?.hasAttribute("disabled")).toBe(false)
  })
})
