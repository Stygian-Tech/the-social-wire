import { describe, expect, it } from "bun:test";
import { filterEntriesForArticleFilter } from "@/lib/entryArticleFilter";
import type { EntryListItem } from "@/lib/atprotoClient";

const makeEntry = (entryId: string): EntryListItem => ({
  entryId,
  title: "T",
  publishedAt: "2026-01-01T00:00:00.000Z",
});

describe("filterEntriesForArticleFilter", () => {
  it("returns all entries when filter is all", () => {
    const a = makeEntry("at://did/a/x/1");
    const b = makeEntry("at://did/a/x/2");
    const out = filterEntriesForArticleFilter([a, b], "all", () => false);
    expect(out).toEqual([a, b]);
  });

  it("excludes read entries when filter is unread", () => {
    const a = makeEntry("at://did/a/x/1");
    const b = makeEntry("at://did/a/x/2");
    const isRead = (id: string) => id === a.entryId;
    const out = filterEntriesForArticleFilter([a, b], "unread", isRead);
    expect(out).toEqual([b]);
  });
});
