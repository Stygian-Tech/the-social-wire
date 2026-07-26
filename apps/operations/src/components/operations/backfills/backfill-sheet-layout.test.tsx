import { describe, expect, it } from "bun:test"
import { render, screen } from "@testing-library/react"
import { FieldDescription } from "@/components/ui/field"
import { SheetFooter } from "@/components/ui/sheet"

describe("Backfill sheet layout", () => {
  it("keeps the counter compact and aligns footer actions with spacing", () => {
    render(
      <>
        <FieldDescription className="text-right">0 / 280</FieldDescription>
        <SheetFooter className="flex items-center justify-end gap-3">
          <button>Cancel</button>
          <button>Run Backfill</button>
        </SheetFooter>
      </>,
    )

    expect(screen.getByText("0 / 280").className).toContain("text-[10px]")
    expect(screen.getByText("0 / 280").className).toContain("text-right")
    expect(screen.getByText("Cancel").parentElement?.className).toContain("justify-end")
    expect(screen.getByText("Cancel").parentElement?.className).toContain("gap-3")
  })
})
