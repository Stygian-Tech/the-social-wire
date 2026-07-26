import { expect, test } from "bun:test"
import { render, screen } from "@testing-library/react"
import { MobileOperationsNav } from "@/components/operations/shell/operations-mobile-nav"

test("gives every mobile destination a 44px minimum touch target", () => {
  render(<MobileOperationsNav current="overview" />)
  for (const link of screen.getAllByRole("link")) expect(link.className).toContain("min-h-11")
})
