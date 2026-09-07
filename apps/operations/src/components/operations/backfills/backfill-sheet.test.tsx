import { afterEach, expect, test } from "bun:test"
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { BackfillSheet } from "@/components/operations/backfills/backfill-sheet"
import { OperationsAuthProvider } from "@/lib/auth-context"

afterEach(cleanup)
process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE = "1"

test("new backfills offer current recovery modes even when old capabilities advertise Tap", async () => {
  render(
    <QueryClientProvider client={new QueryClient()}>
      <OperationsAuthProvider>
        <BackfillSheet
          environment="dev"
          open
          mutationsEnabled
          recoveryModes={{
            tapVerifiedResync: { enabled: true },
            jetstreamReplay: { enabled: true },
            pdsReconciliation: { enabled: true },
          }}
          onOpenChange={() => {}}
        />
      </OperationsAuthProvider>
    </QueryClientProvider>,
  )
  const source = screen.getByRole("combobox", { name: "Source Mode" })
  expect(source.textContent).toContain("Jetstream Replay")
  await act(async () => { fireEvent.click(source) })
  expect(screen.getByRole("option", { name: "Jetstream Replay" })).toBeTruthy()
  expect(screen.getByRole("option", { name: "PDS Diagnostic Reconciliation" })).toBeTruthy()
  expect(screen.queryByRole("option", { name: "Tap Verified Resync" })).toBeNull()
})
