import { describe, expect, it, mock } from "bun:test";
import { importOpmlPodcasts } from "@/lib/podcasts/opmlImport";
import type { PodcastShow } from "@/lib/podcasts/client";
const feed = (name: string) => ({ feedUrl: `https://${name}.example/feed`, title: name, categoryPath: [], sourceIndex: 0 });
const show = (id: string, feedUrl?: string): PodcastShow => ({ id, title: id, sourceKind: "rss", feedUrl });
describe("podcast OPML imports", () => {
  it("skips existing and canonical aliases, deduplicates, and retains partial failures for retry", async () => {
    const subscribe = mock(async () => {});
    const resolve = mock(async (url: string) => {
      if (url.includes("bad")) throw new Error("token=secret");
      return show(url.includes("alias") ? "existing" : "new", url);
    });
    const onProgress = mock(() => {});
    const result = await importOpmlPodcasts({ feeds: [feed("existing"), feed("alias"), feed("fresh"), feed("fresh"), feed("bad")], privateFeeds: false, existingShows: [show("existing", feed("existing").feedUrl)], assertViewer() {}, resolve, subscribe, onProgress });
    expect(result.imported).toHaveLength(1);
    expect(result.skippedExisting).toHaveLength(2);
    expect(result.failed).toHaveLength(1);
    expect(result.failed[0]?.message).not.toContain("secret");
    expect(subscribe).toHaveBeenCalledTimes(1);
    expect(resolve).toHaveBeenCalledTimes(3);
    expect(onProgress).toHaveBeenCalledTimes(4);
  });
  it("routes private feeds through private resolution without any PDS subscription writes", async () => {
    const subscribe = mock(async () => {});
    const resolve = mock(async () => ({ ...show("private"), visibility: "private" as const, sourceKind: "private-rss" as const }));
    const result = await importOpmlPodcasts({ feeds: [feed("paid")], privateFeeds: true, existingShows: [], assertViewer() {}, resolve, subscribe });
    expect(resolve).toHaveBeenCalledWith(feed("paid").feedUrl, true);
    expect(subscribe).not.toHaveBeenCalled();
    expect(result.imported).toHaveLength(1);
  });
  it("stops after an account change during resolution before publishing or processing subsequent feeds", async () => {
    let changed = false;
    const subscribe = mock(async () => {});
    const resolve = mock(async () => { changed = true; return show("new"); });
    await expect(importOpmlPodcasts({ feeds: [feed("one"), feed("two")], privateFeeds: false, existingShows: [], assertViewer() { if (changed) throw new Error("Account Changed"); }, resolve, subscribe })).rejects.toThrow("Account Changed");
    expect(resolve).toHaveBeenCalledTimes(1);
    expect(subscribe).not.toHaveBeenCalled();
  });
});
