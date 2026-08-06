import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";

import * as atprotoClient from "@/lib/atprotoClient";
import type { EntryDetail } from "@/lib/atprotoClient";
import {
  isStandardSiteEntryId,
  resolveEntryOpenUrlFromPds,
} from "@/lib/resolveEntryOpenUrl";

const STANDARD_SITE_ENTRY = "at://did:plc:author/site.standard.document/article";

let getEntrySpy: ReturnType<typeof spyOn<typeof atprotoClient, "getEntry">>;

function entryDetail(fields: Partial<EntryDetail>): EntryDetail {
  return {
    entryId: STANDARD_SITE_ENTRY,
    title: "Article",
    publishedAt: "2026-01-01T00:00:00.000Z",
    ...fields,
  } as EntryDetail;
}

beforeEach(() => {
  getEntrySpy = spyOn(atprotoClient, "getEntry");
});

afterEach(() => {
  getEntrySpy.mockRestore();
});

describe("resolveEntryOpenUrlFromPds", () => {
  it("resolves the hosted URL for a standard.site entry", async () => {
    getEntrySpy.mockResolvedValue(
      entryDetail({ originalUrl: "https://example.com/posts/hello" }),
    );

    expect(await resolveEntryOpenUrlFromPds(STANDARD_SITE_ENTRY)).toBe(
      "https://example.com/posts/hello",
    );
    expect(getEntrySpy).toHaveBeenCalledTimes(1);
  });

  it("falls back to the embed URL when no original URL is recorded", async () => {
    getEntrySpy.mockResolvedValue(
      entryDetail({ embedUrl: "https://example.com/posts/hello" }),
    );

    expect(await resolveEntryOpenUrlFromPds(STANDARD_SITE_ENTRY)).toBe(
      "https://example.com/posts/hello",
    );
  });

  it("short-circuits non-standard.site entries without a network call", async () => {
    expect(await resolveEntryOpenUrlFromPds("rssentry:article")).toBeUndefined();
    expect(
      await resolveEntryOpenUrlFromPds(
        "at://did:plc:author/app.bsky.feed.post/abc",
      ),
    ).toBeUndefined();
    expect(getEntrySpy).not.toHaveBeenCalled();
  });

  it("returns undefined when the record has no destination", async () => {
    getEntrySpy.mockResolvedValue(entryDetail({}));
    expect(
      await resolveEntryOpenUrlFromPds(STANDARD_SITE_ENTRY),
    ).toBeUndefined();
  });

  it("returns undefined when the PDS read fails", async () => {
    getEntrySpy.mockRejectedValue(new Error("network down"));
    expect(
      await resolveEntryOpenUrlFromPds(STANDARD_SITE_ENTRY),
    ).toBeUndefined();
  });
});

describe("isStandardSiteEntryId", () => {
  it("covers site.standard and legacy com.standard collections", () => {
    expect(isStandardSiteEntryId(STANDARD_SITE_ENTRY)).toBe(true);
    expect(
      isStandardSiteEntryId("at://did:plc:author/site.standard.entry/article"),
    ).toBe(true);
    expect(
      isStandardSiteEntryId("at://did:plc:author/com.standard.document/article"),
    ).toBe(true);
    expect(isStandardSiteEntryId("rssentry:article")).toBe(false);
  });
});
