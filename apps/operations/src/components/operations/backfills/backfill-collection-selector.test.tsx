import { afterEach, describe, expect, it, mock } from "bun:test"
import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import { BackfillCollectionSelector } from "@/components/operations/backfills/backfill-collection-selector"
import { BACKFILL_COLLECTION_OPTIONS } from "@/lib/backfill-collections"

afterEach(cleanup)

describe("BackfillCollectionSelector", () => {
  it("requires an explicit selection when the collection scope is unknown", () => {
    const onValueChange = mock(() => undefined)

    render(<BackfillCollectionSelector value={[]} options={BACKFILL_COLLECTION_OPTIONS} onValueChange={onValueChange} />)

    expect(screen.getByRole("alert").textContent).toContain("Scope unknown")
    expect(screen.getAllByRole("checkbox").every((checkbox) => !(checkbox as HTMLInputElement).checked)).toBe(true)

    fireEvent.click(screen.getByRole("checkbox", { name: "site.standard.entry" }))

    expect(onValueChange).toHaveBeenCalledWith(["site.standard.entry"])
  })

  it("keeps an attributed collection selected", () => {
    render(<BackfillCollectionSelector value={["app.skyreader.feed.subscription"]} options={BACKFILL_COLLECTION_OPTIONS} onValueChange={() => undefined} />)

    expect(screen.queryByRole("alert")).toBeNull()
    expect(
      (screen.getByRole("checkbox", { name: "app.skyreader.feed.subscription" }) as HTMLInputElement).checked,
    ).toBe(true)
  })

  it("labels legacy scope as diagnostic-only instead of offering it", () => {
    render(
      <BackfillCollectionSelector
        value={[]}
        options={BACKFILL_COLLECTION_OPTIONS}
        legacyCollections={["com.standard.document"]}
        onValueChange={() => undefined}
      />,
    )

    expect(screen.queryByRole("checkbox", { name: "com.standard.document" })).toBeNull()
    expect(screen.getByText(/not a registered recovery collection/)).toBeTruthy()
  })

  it("withholds collections outside the selected source mode coverage", () => {
    render(
      <BackfillCollectionSelector
        value={[]}
        options={["site.standard.document", "site.standard.entry"]}
        legacyCollections={["app.skyreader.feed.subscription"]}
        onValueChange={() => undefined}
      />,
    )

    expect(screen.queryByRole("checkbox", { name: "app.skyreader.feed.subscription" })).toBeNull()
    expect(screen.getByText(/outside this source mode/)).toBeTruthy()
  })
})
