import { describe, expect, it } from "bun:test";

import { entriesNextPageParam } from "@/hooks/useEntries";

describe("entriesNextPageParam", () => {
  it("returns undefined when the last page has no cursor", () => {
    expect(
      entriesNextPageParam({ entries: [{ entryId: "a" } as never], cursor: undefined }, [], undefined)
    ).toBeUndefined();
  });

  it("returns the cursor when the page has entries", () => {
    expect(
      entriesNextPageParam(
        { entries: [{ entryId: "a" } as never], cursor: "2026-01-01T00:00:00.000Z|at://did/entry/1" },
        [],
        undefined
      )
    ).toBe("2026-01-01T00:00:00.000Z|at://did/entry/1");
  });

  it("stops when an empty page repeats the same cursor", () => {
    const cursor = "2026-01-01T00:00:00.000Z|at://did/entry/1";
    expect(
      entriesNextPageParam({ entries: [], cursor }, [{ entries: [] }], cursor)
    ).toBeUndefined();
  });

  it("continues scanning when an empty page advances the cursor", () => {
    const nextCursor = "2026-01-02T00:00:00.000Z|at://did/entry/2";
    expect(
      entriesNextPageParam(
        { entries: [], cursor: nextCursor },
        [{ entries: [] }],
        "2026-01-01T00:00:00.000Z|at://did/entry/1"
      )
    ).toBe(nextCursor);
  });
});
