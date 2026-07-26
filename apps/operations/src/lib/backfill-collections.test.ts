import { describe, expect, it } from "bun:test"
import {
  gapCollectionScopeLabel,
  initialBackfillCollections,
  recoveryCollectionOptions,
} from "@/lib/backfill-collections"

describe("backfill collection scope", () => {
  it("does not substitute a default collection for an unknown scope", () => {
    expect(initialBackfillCollections([])).toEqual([])
    expect(gapCollectionScopeLabel([])).toBe("Unknown")
  })

  it("withholds unregistered legacy collections from recovery scope", () => {
    expect(initialBackfillCollections(["com.standard.document", "site.standard.document"])).toEqual([
      "site.standard.document",
    ])
  })

  it("limits Tap and PDS diagnostics to their registered canonical coverage", () => {
    expect(recoveryCollectionOptions("tap_verified_resync")).toEqual([
      "site.standard.document",
      "site.standard.entry",
    ])
    expect(
      initialBackfillCollections(
        ["site.standard.document", "app.skyreader.feed.subscription"],
        "pds_reconciliation",
      ),
    ).toEqual(["site.standard.document"])
    expect(recoveryCollectionOptions("jetstream_replay")).toContain("app.skyreader.feed.subscription")
  })
})
