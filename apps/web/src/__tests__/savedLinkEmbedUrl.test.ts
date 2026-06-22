import { describe, expect, it } from "bun:test";
import {
  isPoorIframeEmbedTarget,
  isPocketReaderHostname,
  resolveSavedLinkEmbedUrl,
} from "@/lib/savedLinkEmbedUrl";
import type { MergedLatrSave } from "@/lib/pdsClient";

describe("savedLinkEmbedUrl", () => {
  it("only treats actual Pocket reader wrappers as poor iframe targets", () => {
    expect(isPocketReaderHostname("getpocket.com")).toBe(true);
    expect(isPocketReaderHostname("app.getpocket.com")).toBe(true);
    expect(isPocketReaderHostname("pckt.it")).toBe(false);
    expect(isPoorIframeEmbedTarget("https://getpocket.com/read/123456")).toBe(
      true
    );
    expect(isPoorIframeEmbedTarget("https://example.leaflet.pub/post")).toBe(
      false
    );
    expect(isPoorIframeEmbedTarget("https://notes.offprint.app/a/hello")).toBe(
      false
    );
    expect(isPoorIframeEmbedTarget("https://pckt.it/article")).toBe(false);
    expect(isPoorIframeEmbedTarget("https://example.com/article")).toBe(false);
  });

  it("prefers linkedWebUrl over Pocket reader wrapper URLs", () => {
    const row: MergedLatrSave = {
      kind: "external",
      normalizedUrl: "https://example.com/post",
      url: "https://getpocket.com/read/123456",
      savedAt: "2026-01-01T00:00:00.000Z",
      externalRkey: "ext",
      itemRkey: "item",
      externalUri: "at://did/com.latr.saved.external/ext",
      itemUri: "at://did/com.latr.saved.item/item",
      subjectUri: "at://did/com.latr.saved.external/ext",
      linkedWebUrl: "https://example.com/post",
    };
    expect(resolveSavedLinkEmbedUrl(row)).toBe("https://example.com/post");
  });

  it("falls back to primary URL for normal external saves", () => {
    const row: MergedLatrSave = {
      kind: "external",
      normalizedUrl: "https://example.com/post",
      url: "https://example.com/post",
      savedAt: "2026-01-01T00:00:00.000Z",
      externalRkey: "ext",
      itemRkey: "item",
      externalUri: "at://did/com.latr.saved.external/ext",
      itemUri: "at://did/com.latr.saved.item/item",
      subjectUri: "at://did/com.latr.saved.external/ext",
    };
    expect(resolveSavedLinkEmbedUrl(row)).toBe("https://example.com/post");
  });
});
