import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { BackfillStatusIndicator } from "@/components/operations/backfills/backfill-status-indicator"

afterEach(cleanup)

describe("BackfillStatusIndicator", () => {
  it("makes a running job explicit and animated", () => {
    const { container } = render(<BackfillStatusIndicator status="running" />)

    expect(screen.getByText("Running")).toBeTruthy()
    expect(
      container.querySelector('[class*="motion-safe:animate-ping"]'),
    ).toBeTruthy()
  })

  it("uses a final label without a running animation", () => {
    const { container } = render(<BackfillStatusIndicator status="completed" />)

    expect(screen.getByText("Completed")).toBeTruthy()
    expect(
      container.querySelector('[class*="motion-safe:animate-ping"]'),
    ).toBeNull()
  })
})
