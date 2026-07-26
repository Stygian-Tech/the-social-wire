import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { GapCollectionScope } from "@/components/operations/gaps/gap-collection-scope"

afterEach(cleanup)

describe("GapCollectionScope", () => {
  it("labels an unattributed gap as unknown", () => {
    render(<GapCollectionScope collections={[]} />)

    expect(screen.getByText("Unknown").getAttribute("title")).toContain("could not attribute")
  })

  it("shows the number of attributed collections", () => {
    render(<GapCollectionScope collections={["site.standard.document", "site.standard.entry"]} />)

    expect(screen.getByText("2").getAttribute("title")).toBe("site.standard.document, site.standard.entry")
  })
})
