import { describe, expect, it } from "bun:test";
import type { InfiniteData } from "@tanstack/react-query";

import type { EntriesPage } from "@/hooks/useEntries";
import {
  mergeFeedRefreshForFilter,
  unreadFeedPlaceholder,
} from "@/lib/feedCacheMerge";

function cachedFeed(): InfiniteData<EntriesPage, string | undefined> {
  return {
    pages: [
      {
        entries: [
          {
            entryId: "at://did:plc:alice/site.standard.document/unread",
            title: "Unread",
            publishedAt: "2026-01-02T00:00:00.000Z",
            isRead: false,
          },
          {
            entryId: "at://did:plc:alice/site.standard.document/read",
            title: "Read",
            publishedAt: "2026-01-01T00:00:00.000Z",
            isRead: true,
          },
        ],
        cursor: "all-cursor",
      },
    ],
    pageParams: [undefined],
  };
}

describe("feed cache filtering", () => {
  it("paints cached unread rows without reusing the All cursor", () => {
    const placeholder = unreadFeedPlaceholder(cachedFeed());

    expect(placeholder?.pages[0].entries.map((entry) => entry.title)).toEqual([
      "Unread",
    ]);
    expect(placeholder?.pages[0].cursor).toBeUndefined();
  });

  it("replaces unread cache pages with the authoritative first page", () => {
    const refreshed = mergeFeedRefreshForFilter(
      cachedFeed(),
      {
        entries: [
          {
            entryId: "at://did:plc:alice/site.standard.document/fresh",
            title: "Fresh",
            publishedAt: "2026-01-03T00:00:00.000Z",
            isRead: false,
          },
        ],
        cursor: "unread-cursor",
      },
      "unread"
    );

    expect(refreshed.pages).toHaveLength(1);
    expect(refreshed.pages[0].entries.map((entry) => entry.title)).toEqual([
      "Fresh",
    ]);
    expect(refreshed.pages[0].cursor).toBe("unread-cursor");
  });
});
