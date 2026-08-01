import { describe, expect, it } from "bun:test";

import type { MergedLatrSave } from "@/lib/pdsClient";
import type { SidebarPublicationRow } from "@/lib/publicationProjectionClient";
import {
  rssEntryIdFromParts,
  rssPublicationIdFromNormalizedFeedUrl,
  stableItemKeyFromRssItem,
} from "@/lib/rssFeedCore";
import { savedLinkOpenTarget } from "@/lib/savedLinkOpenTarget";

const articleUrl = "https://publisher.example/articles/rss-reader";
const feedUrl = "https://publisher.example/feed.xml";

const savedRow: MergedLatrSave = {
  kind: "external",
  normalizedUrl: articleUrl,
  url: articleUrl,
  savedAt: "2026-08-01T00:00:00.000Z",
  externalRkey: "external",
  itemRkey: "item",
  externalUri: "at://did:plc:viewer/link.latr.saved.external/external",
  itemUri: "at://did:plc:viewer/link.latr.saved.item/item",
  subjectUri: "at://did:plc:viewer/link.latr.saved.external/external",
  title: "Saved RSS Article",
};

const rssPublicationId = rssPublicationIdFromNormalizedFeedUrl(feedUrl);
const rssSidebarRow: SidebarPublicationRow = {
  publicationId: rssPublicationId,
  subscriptionPublicationId: rssPublicationId,
  authorDid: "did:web:skyreader.rss",
  authorHandle: "publisher.example",
  title: "Publisher RSS",
  discoveredAt: "2026-08-01T00:00:00.000Z",
  appViewScope: {
    authorDid: "did:web:skyreader.rss",
    publicationAtUri: null,
    publicationScopeAtUris: [],
    publicationSiteUrls: [feedUrl, "https://publisher.example"],
  },
};

describe("savedLinkOpenTarget", () => {
  it("opens ordinary Read Later links in a new tab target", () => {
    expect(savedLinkOpenTarget(savedRow, [], "reader")).toEqual({
      kind: "external",
      url: articleUrl,
    });
  });

  it("opens saved RSS content in the native reader when preferred", () => {
    expect(savedLinkOpenTarget(savedRow, [rssSidebarRow], "reader")).toEqual({
      kind: "rssReader",
      url: articleUrl,
      entryId: rssEntryIdFromParts(
        feedUrl,
        stableItemKeyFromRssItem({ link: articleUrl }),
      ),
    });
  });

  it("opens saved RSS content on the original site when preferred", () => {
    expect(savedLinkOpenTarget(savedRow, [rssSidebarRow], "original")).toEqual({
      kind: "external",
      url: articleUrl,
    });
  });
});
