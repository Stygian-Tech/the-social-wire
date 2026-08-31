import { describe, expect, it } from "bun:test";

import {
  countLatrTags,
  filterLatrSavesByExactTag,
  normalizeLatrTags,
  parseLatrTagInput,
  replaceLatrTag,
} from "@/lib/latrTags";
import type { MergedLatrSave } from "@/lib/pdsClient";

function row(itemRkey: string, tags?: string[]): MergedLatrSave {
  return {
    kind: "native",
    savedAt: "2026-08-30T00:00:00Z",
    itemRkey,
    itemUri: `at://did:plc:viewer/community.lexicon.bookmarks.bookmark/${itemRkey}`,
    subjectUri: `at://did:plc:author/site.standard.document/${itemRkey}`,
    ...(tags ? { tags } : {}),
  };
}

describe("L@tr tags", () => {
  it("trims, deduplicates, and preserves exact case", () => {
    expect(normalizeLatrTags([" Research ", "research", "Research", ""])).toEqual([
      "Research",
      "research",
    ]);
    expect(parseLatrTagInput("Research, Weekend\nLong Reads")).toEqual([
      "Research",
      "Weekend",
      "Long Reads",
    ]);
  });

  it("filters by exact tag without substring or case folding", () => {
    const rows = [
      row("one", ["Research"]),
      row("two", ["research", "Research Notes"]),
      row("three"),
    ];
    expect(filterLatrSavesByExactTag(rows, "Research").map((item) => item.itemRkey)).toEqual([
      "one",
    ]);
    expect(filterLatrSavesByExactTag(rows, "research").map((item) => item.itemRkey)).toEqual([
      "two",
    ]);
  });

  it("renames or clears one exact tag while preserving the rest", () => {
    expect(replaceLatrTag(["News", "Later"], "News", "Reading")).toEqual([
      "Reading",
      "Later",
    ]);
    expect(replaceLatrTag(["News", "Later"], "News")).toEqual(["Later"]);
  });

  it("counts exact tags only within the current saved view", () => {
    expect(countLatrTags([
      row("one", ["News", "swift"]),
      row("two", ["news", "swift"]),
    ])).toEqual([
      { tag: "News", count: 1 },
      { tag: "news", count: 1 },
      { tag: "swift", count: 2 },
    ]);
  });
});
