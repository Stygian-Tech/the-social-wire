import { describe, expect, it } from "bun:test";
import { QueryClient } from "@tanstack/react-query";

import { writeStreamedEntriesPage } from "@/lib/bootstrapStreamState";
import { ENTRIES_QUERY_KEY } from "@/hooks/useEntries";

describe("writeStreamedEntriesPage", () => {
  it("normalizes publication ids for the entries query cache key", () => {
    const qc = new QueryClient();
    writeStreamedEntriesPage(qc, {
      publicationId: "at://did:plc:author/site.standard.publication/pub1",
      entries: [{ entryId: "at://did:plc:author/site.standard.document/a", title: "A", publishedAt: "2026-01-01T00:00:00.000Z" }],
      cursor: "next",
    });

    const cached = qc.getQueryData([
      ...ENTRIES_QUERY_KEY("at://did:plc:author/site.standard.publication/pub1"),
      "all",
    ]);
    expect(cached).toBeDefined();
  });
});
