import { expect, test } from "bun:test"
import { render, screen } from "@testing-library/react"
import { Button } from "@/components/ui/button"

test("provides a 44px minimum target for default and icon controls", () => {
  render(
    <>
      <Button>Run Action</Button>
      <Button size="icon" aria-label="Refresh Operations Data">R</Button>
    </>,
  )

  expect(screen.getByRole("button", { name: "Run Action" }).className).toContain("min-h-11")
  expect(screen.getByRole("button", { name: "Refresh Operations Data" }).className).toContain("size-11")
})
