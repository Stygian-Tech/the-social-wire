import { expect, test } from "bun:test"
import { render, screen } from "@testing-library/react"
import { CapabilityStatus } from "@/components/operations/dashboard/capability-status"
import { demoOverview } from "@/lib/demo-data"

test("shows disabled capability reasons", () => {
  render(<CapabilityStatus overview={demoOverview} />)
  expect(screen.getAllByText("Synthetic demo data is read-only")).toHaveLength(3)
  expect(screen.getByText(/Pinned Tap does not yet provide a safe resync endpoint/)).toBeTruthy()
  expect(screen.getByText("Synthetic demo data does not deliver alerts")).toBeTruthy()
})
