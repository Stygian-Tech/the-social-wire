import { describe, expect, it } from "bun:test";
import type { InfiniteData } from "@tanstack/react-query";

import type { EntriesPage } from "@/hooks/useEntries";
import { mergeFeedFirstPageRefresh } from "@/lib/feedRefresh";

const entry = (id: string, title: string) => ({
  entryId: id,
  title,
  publishedAt: "2026-01-01T00:00:00.000Z",
  summary: null,
  articleUrl: null,
});

describe("mergeFeedFirstPageRefresh", () => {
  it("prepends new posts without dropping paginated tail pages", () => {
    const existing: InfiniteData<EntriesPage> = {
      pages: [
        {
          entries: [entry("a", "A"), entry("b", "B")],
          cursor: "page2",
        },
        {
          entries: [entry("c", "C")],
          cursor: undefined,
        },
      ],
      pageParams: [undefined, "page2"],
    };

    const fresh: EntriesPage = {
      entries: [entry("new", "New"), entry("b", "B updated")],
      cursor: "page2",
    };

    const merged = mergeFeedFirstPageRefresh(existing, fresh);

    expect(merged.pages).toHaveLength(2);
    expect(merged.pages[0]?.entries.map((e) => e.entryId)).toEqual([
      "new",
      "b",
      "a",
    ]);
    expect(merged.pages[1]?.entries.map((e) => e.entryId)).toEqual(["c"]);
    expect(merged.pageParams).toEqual([undefined, "page2"]);
  });

  it("seeds cache when no prior pages exist", () => {
    const fresh: EntriesPage = {
      entries: [entry("a", "A")],
      cursor: undefined,
    };

    const merged = mergeFeedFirstPageRefresh(undefined, fresh);
    expect(merged.pages).toHaveLength(1);
    expect(merged.pages[0]?.entries).toHaveLength(1);
  });
});
