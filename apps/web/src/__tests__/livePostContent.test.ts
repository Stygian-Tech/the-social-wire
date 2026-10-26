import { expect, test } from "bun:test";
import { appendLiveArticleContent } from "@/lib/livePosts/livePostContent";
import type { ArticleHost, ArticleRecord } from "@/lib/articles/articlePublishingTypes";
import type { PreparedLivePostMedia } from "@/lib/livePosts/livePostMedia";
const image = { blob: { $type: "blob" as const, ref: { $link: "bafkreiimage" }, mimeType: "image/png", size: 50 }, alt: "A [scene]", aspectRatio: { width: 640, height: 480 } };
const media: PreparedLivePostMedia = { pdsUrl: "https://alice.pds.example", images: [image] };
test("Markdown images reference the account PDS and preserve image format and literal alt", () => {
  const next = appendLiveArticleContent("markpub", undefined, "Now", "Update", media, "did:plc:alice");
  expect((next.text as ArticleRecord).markdown).toContain("![A \\[scene\\]](https://alice.pds.example/xrpc/com.atproto.sync.getBlob?did=did%3Aplc%3Aalice&cid=bafkreiimage)");
  expect(() => appendLiveArticleContent("markpub", undefined, "Now", "Update", { images: [image] }, "did:plc:alice")).toThrow("PDS endpoint");
});
for (const host of ["leaflet", "offprint", "pckt"] satisfies ArticleHost[]) test(`${host} appends native images while preserving previous content`, () => {
  const initial = appendLiveArticleContent(host, undefined, "First", "Earlier");
  const before = JSON.stringify(initial);
  const next = appendLiveArticleContent(host, initial, "Second", "Update", media, "did:plc:alice");
  expect(JSON.stringify(initial)).toBe(before);
  expect(JSON.stringify(next)).toContain("bafkreiimage"); expect(JSON.stringify(next)).toContain("A [scene]"); expect(JSON.stringify(next)).toContain("Earlier");
  const items = host === "leaflet" ? ((next.pages as ArticleRecord[])[0].blocks as ArticleRecord[]).map(item => item.block as ArticleRecord) : next.items as ArticleRecord[];
  expect(items.at(-1)?.$type).toContain("image");
});
test("video, GIF and link attachments remain in native blocks and Markdown", () => {
  const attachments: PreparedLivePostMedia = { pdsUrl: "https://alice.pds.example", video: { blob: { ...image.blob, mimeType: "video/mp4" }, alt: "Video" }, gif: { url: "https://example.com/animated.gif", alt: "Animation" }, external: { $type: "app.bsky.embed.external", external: { uri: "https://example.com/story", title: "Story", description: "A story" } } };
  for (const host of ["leaflet", "offprint", "pckt", "markpub"] satisfies ArticleHost[]) {
    const content = JSON.stringify(appendLiveArticleContent(host, undefined, "Now", "Update", attachments, "did:plc:alice"));
    expect(content).toContain("https://alice.pds.example"); expect(content).toContain("https://example.com/animated.gif"); expect(content).toContain("https://example.com/story");
  }
});
