import { describe, expect, it, mock } from "bun:test";

import {
  bookmarkViewToRow,
  migrateLegacyBookmarks,
} from "@/lib/latrBookmarks";

describe("bookmarkViewToRow", () => {
  it("maps gateway preview and archive metadata without a wrapper", () => {
    const row = bookmarkViewToRow({
      uri: "at://did:plc:viewer/community.lexicon.bookmarks.bookmark/one",
      cid: "bafy-one",
      value: {
        $type: "community.lexicon.bookmarks.bookmark",
        subject: "https://example.com/article",
        createdAt: "2026-08-13T00:00:00Z",
        tags: ["news"],
      },
      metadataRecord: {
        uri: "at://did:plc:viewer/link.latr.bookmarks.metadata/one",
        cid: "bafy-meta",
        value: {
          $type: "link.latr.bookmarks.metadata",
          bookmarkUri: "at://did:plc:viewer/community.lexicon.bookmarks.bookmark/one",
          subject: "https://example.com/article",
          state: "archived",
        },
      },
      preview: {
        title: "Article",
        description: "Summary",
        image: "https://example.com/image.jpg",
        siteName: "Example",
        author: "Sam",
      },
    });

    expect(row.kind).toBe("external");
    expect(row.subjectUri).toBe("https://example.com/article");
    expect(row.itemRkey).toBe(
      "at://did:plc:viewer/community.lexicon.bookmarks.bookmark/one"
    );
    expect(row.state).toBe("archived");
    expect(row.tags).toEqual(["news"]);
    expect(row.title).toBe("Article");
    expect(row.excerpt).toBe("Summary");
  });

  it("retains AT URI subjects for native fallback opening", () => {
    const row = bookmarkViewToRow({
      uri: "at://did:plc:viewer/community.lexicon.bookmarks.bookmark/two",
      cid: "bafy-two",
      value: {
        $type: "community.lexicon.bookmarks.bookmark",
        subject: "at://did:plc:author/site.standard.document/post",
        createdAt: "2026-08-13T00:00:00Z",
      },
    });
    expect(row.kind).toBe("native");
    expect(row.subjectUri).toBe(
      "at://did:plc:author/site.standard.document/post"
    );
  });
});

describe("migrateLegacyBookmarks", () => {
  it("runs every cursor and aggregates conflicts", async () => {
    const migratePage = mock(async ({ cursor }: { cursor?: string }) =>
      cursor
        ? {
            ok: true,
            scanned: 1,
            created: 0,
            reused: 0,
            duplicates: 0,
            skippedConflict: 1,
            cached: 0,
            retired: 0,
          }
        : {
            ok: true,
            scanned: 2,
            created: 2,
            reused: 0,
            duplicates: 0,
            skippedConflict: 0,
            cached: 0,
            retired: 2,
            cursor: "next",
          }
    );
    const result = await migrateLegacyBookmarks({ migratePage });
    expect(migratePage).toHaveBeenCalledTimes(2);
    expect(result.scanned).toBe(3);
    expect(result.retired).toBe(2);
    expect(result.hasConflicts).toBe(true);
  });

  it("stops immediately on a failed migration page", async () => {
    const migratePage = mock(async () => {
      throw new Error("transport failed");
    });
    await expect(migrateLegacyBookmarks({ migratePage })).rejects.toThrow(
      "transport failed"
    );
    expect(migratePage).toHaveBeenCalledTimes(1);
  });

  it("does not treat an unsuccessful result envelope as completion", async () => {
    const migratePage = mock(async () => ({
      ok: false,
      scanned: 1,
      created: 0,
      reused: 0,
      duplicates: 0,
      skippedConflict: 0,
      cached: 0,
      retired: 0,
    }));
    await expect(migrateLegacyBookmarks({ migratePage })).rejects.toThrow(
      "did not complete",
    );
  });
});
