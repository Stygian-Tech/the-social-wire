import { describe, expect, it } from "bun:test"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { DataColumnHeaders } from "@/components/operations/data-column-headers"

describe("DataColumnHeaders", () => {
  it("shows explanations when a column title is hovered", async () => {
    render(
      <table>
        <thead>
          <tr>
            <DataColumnHeaders labels={["Collection", "Total Latency"]} />
          </tr>
        </thead>
      </table>,
    )

    fireEvent.mouseEnter(screen.getByText("Collection"))

    await waitFor(() => {
      expect(screen.getByRole("tooltip").textContent).toContain("The ATProto collection represented by this row.")
    })
    expect(screen.getByText("Total Latency").getAttribute("tabindex")).toBe("0")
  })
})
