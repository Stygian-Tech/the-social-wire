import { describe, expect, it } from "bun:test";
import {
  filterEntriesForArticleFilter,
  shouldShowNoUnreadEntriesState,
} from "@/lib/entryArticleFilter";
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

describe("shouldShowNoUnreadEntriesState", () => {
  const base = {
    effectiveFilter: "unread" as const,
    visibleEntryCount: 0,
    hasNextPage: false,
    isFetchingNextPage: false,
  };

  it("reports empty only once pagination is exhausted", () => {
    expect(shouldShowNoUnreadEntriesState(base)).toBe(true);
  });

  it("keeps streaming while more pages remain", () => {
    // Regression: a large backlog of read articles used to blank the column
    // behind a skeleton until the whole feed had been scanned.
    expect(
      shouldShowNoUnreadEntriesState({ ...base, hasNextPage: true })
    ).toBe(false);
    expect(
      shouldShowNoUnreadEntriesState({ ...base, isFetchingNextPage: true })
    ).toBe(false);
  });

  it("never reports empty once unread entries are visible", () => {
    expect(
      shouldShowNoUnreadEntriesState({ ...base, visibleEntryCount: 1 })
    ).toBe(false);
  });

  it("does not apply to the all filter", () => {
    expect(
      shouldShowNoUnreadEntriesState({ ...base, effectiveFilter: "all" })
    ).toBe(false);
  });
});
