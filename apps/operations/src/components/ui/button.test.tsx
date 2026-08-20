import { expect, test } from "bun:test"
import { render, screen } from "@testing-library/react"
import { Button } from "@/components/ui/button"

test("keeps fine-pointer controls compact and coarse-pointer targets accessible", () => {
  render(
    <>
      <Button>Run Action</Button>
      <Button size="sm">Small Action</Button>
      <Button size="icon" aria-label="Refresh Operations Data">R</Button>
      <Button variant="destructive">Clear Signal</Button>
    </>,
  )

  expect(screen.getByRole("button", { name: "Run Action" }).className).toContain("h-8")
  expect(screen.getByRole("button", { name: "Run Action" }).className).toContain("[@media(pointer:coarse)]:min-h-11")
  expect(screen.getByRole("button", { name: "Small Action" }).className).toContain("h-7")
  expect(screen.getByRole("button", { name: "Refresh Operations Data" }).className).toContain("size-8")
  expect(screen.getByRole("button", { name: "Refresh Operations Data" }).className).toContain("[@media(pointer:coarse)]:size-11")
  expect(screen.getByRole("button", { name: "Clear Signal" }).className).toContain("bg-destructive/10")
})
