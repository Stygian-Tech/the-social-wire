import { afterEach, expect, test } from "bun:test"
import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { MobileOperationsNav } from "@/components/operations/shell/operations-mobile-nav"

afterEach(cleanup)

test("gives every mobile destination a 44px minimum touch target", async () => {
  render(<MobileOperationsNav current="overview" />)
  fireEvent.click(screen.getByRole("button", { name: "Open Operations Navigation" }))
  for (const link of await screen.findAllByRole("link")) expect(link.className).toContain("min-h-11")
})
