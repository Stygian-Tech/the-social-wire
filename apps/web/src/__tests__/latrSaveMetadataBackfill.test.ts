import { describe, expect, it } from "bun:test";

import {
  backfillUrlForLatrSave,
  isLatrSaveMetadataSparse,
  isWeakLatrSaveTitle,
  mergeLatrSaveBackfillMetadata,
  needsLatrSaveOgBackfill,
} from "@/lib/latrSaveMetadataBackfill";
import type { MergedLatrSave } from "@/lib/pdsClient";

describe("latrSaveMetadataBackfill", () => {
  const externalRow: MergedLatrSave = {
    kind: "external",
    normalizedUrl: "https://example.com/article",
    url: "https://example.com/article",
    savedAt: "2026-06-01T12:00:00.000Z",
    externalRkey: "EXT",
    itemRkey: "ITEM",
    externalUri: "at://did/com.latr.saved.external/EXT",
    itemUri: "at://did/com.latr.saved.item/ITEM",
    subjectUri: "at://did/com.latr.saved.external/EXT",
  };

  it("detects sparse external rows missing image and title", () => {
    expect(isLatrSaveMetadataSparse(externalRow)).toBe(true);
    expect(needsLatrSaveOgBackfill(externalRow)).toBe(true);
  });

  it("detects hostname-only titles as sparse", () => {
    expect(
      isLatrSaveMetadataSparse({
        ...externalRow,
        title: "example.com",
        image: "https://example.com/thumb.jpg",
      })
    ).toBe(true);
  });

  it("detects site-label titles as weak", () => {
    const url = "https://www.nytimes.com/2026/05/31/us/politics/story.html";
    expect(
      isWeakLatrSaveTitle("The New York Times", "The New York Times", url)
    ).toBe(true);
    expect(
      needsLatrSaveOgBackfill({
        ...externalRow,
        url,
        normalizedUrl: url,
        title: "The New York Times",
        site: "The New York Times",
        image: "https://example.com/thumb.jpg",
      })
    ).toBe(true);
  });

  it("treats enriched rows as complete", () => {
    expect(
      isLatrSaveMetadataSparse({
        ...externalRow,
        title: "Example Article",
        image: "https://example.com/thumb.jpg",
      })
    ).toBe(false);
  });

  it("still backfills missing NYT thumbnails when title looks complete", () => {
    expect(
      needsLatrSaveOgBackfill({
        ...externalRow,
        title: "Trump and Iran Stalemate",
        linkedWebUrl: "https://www.nytimes.com/2026/05/31/us/politics/story.html",
        url: "https://www.nytimes.com/2026/05/31/us/politics/story.html",
        normalizedUrl: "https://www.nytimes.com/2026/05/31/us/politics/story.html",
      })
    ).toBe(true);
  });

  it("resolves backfill URL for external and native rows", () => {
    expect(backfillUrlForLatrSave(externalRow)).toBe("https://example.com/article");

    const nativeRow: MergedLatrSave = {
      kind: "native",
      savedAt: "2026-06-01T12:00:00.000Z",
      itemRkey: "ITEM2",
      itemUri: "at://did/com.latr.saved.item/ITEM2",
      subjectUri: "at://did/app/site.standard.document/abc",
      linkedWebUrl: "https://news.example/story",
    };
    expect(backfillUrlForLatrSave(nativeRow)).toBe("https://news.example/story");
  });

  it("replaces weak titles from OG backfill but keeps strong titles", () => {
    const url = "https://www.nytimes.com/2026/05/31/us/politics/story.html";
    const weakMerged = mergeLatrSaveBackfillMetadata(
      {
        ...externalRow,
        url,
        normalizedUrl: url,
        title: "The New York Times",
        site: "The New York Times",
      },
      {
        title: "Trump and Iran Stalemate",
        image: "https://static01.nyt.com/thumb.jpg",
      }
    );
    expect(weakMerged.title).toBe("Trump and Iran Stalemate");
    expect(weakMerged.image).toBe("https://static01.nyt.com/thumb.jpg");

    const strongMerged = mergeLatrSaveBackfillMetadata(
      {
        ...externalRow,
        title: "Already Good Headline",
      },
      {
        title: "OG Title Should Not Win",
        image: "https://cdn.example/thumb.jpg",
      }
    );
    expect(strongMerged.title).toBe("Already Good Headline");
    expect(strongMerged.image).toBe("https://cdn.example/thumb.jpg");
  });

  it("merges preview fields without clobbering existing metadata", () => {
    const merged = mergeLatrSaveBackfillMetadata(
      { ...externalRow, title: "Kept title", image: "https://existing/thumb.jpg" },
      {
        title: "Preview title",
        excerpt: "Preview excerpt",
        image: "https://cdn.example/thumb.jpg",
        site: "Example",
      }
    );

    expect(merged.title).toBe("Kept title");
    expect(merged.excerpt).toBe("Preview excerpt");
    expect(merged.image).toBe("https://existing/thumb.jpg");
    expect(merged.site).toBe("Example");
  });
});
