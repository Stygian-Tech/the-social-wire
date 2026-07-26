import { describe, expect, it } from "bun:test";
import { firstUnreadPriorityPublicationId } from "@/lib/bootstrapStreamModels";
import { parseNdjsonLinesForTest } from "@/lib/bootstrapStreamClient";
import {
  applySidebarPriorityEvent,
  applyUnreadCountsEvent,
} from "@/lib/bootstrapStreamState";
import type { PublicationSidebarProjection } from "@/lib/publicationProjectionClient";

const baseProjection = (): PublicationSidebarProjection => ({
  viewerDid: "did:plc:viewer",
  folders: [],
  publicationPrefs: [],
  allPublicationRows: [],
  myPublications: [],
  subscribedUnfoldered: [
    {
      publicationId: "pub-a",
      authorDid: "did:plc:a",
      authorHandle: "a",
      title: "A",
      discoveredAt: "2026-01-01T00:00:00.000Z",
      appViewScope: {
        authorDid: "did:plc:a",
        publicationAtUri: null,
        publicationScopeAtUris: [],
        publicationSiteUrls: [],
      },
    },
  ],
  followingTabPublications: [],
  enrollAuthorDids: [],
  refreshedAt: "2026-01-01T00:00:00.000Z",
});

describe("bootstrapStreamModels", () => {
  it("selects first priority publication with unread count", () => {
    const id = firstUnreadPriorityPublicationId({
      myPublications: [],
      subscribedUnfoldered: baseProjection().subscribedUnfoldered,
      followingTabPublications: [],
      unreadCounts: { "pub-a": 3 },
    });
    expect(id).toBe("pub-a");
  });
});

describe("bootstrapStreamClient", () => {
  it("parses partial and multi-line NDJSON chunks", () => {
    const events = parseNdjsonLinesForTest(
      '{"kind":"sidebarPriority","sidebarPriority":{"viewerDid":"did:plc:viewer","folders":[],"publicationPrefs":[],"allPublicationRows":[],"myPublications":[],"subscribedUnfoldered":[],"followingTabPublications":[],"enrollAuthorDids":[],"refreshedAt":"2026-01-01T00:00:00.000Z"}}\n{"kind":"done","done":{"refreshedAt":"2026-01-01T00:00:00.000Z"}}\n'
    );
    expect(events).toHaveLength(2);
    expect(events[0]?.kind).toBe("sidebarPriority");
    expect(events[1]?.kind).toBe("done");
  });

  it("parses sidebarSection NDJSON events", () => {
    const events = parseNdjsonLinesForTest(
      '{"kind":"sidebarSection","sidebarSection":{"sectionKey":"folder:news","folderRkey":"news","folderUri":"at://did:plc:viewer/app.thesocialwire.folder/news","publications":[],"unreadCounts":{"pub-a":0},"replacePublicationIds":["pub-a"],"refreshedAt":"2026-01-01T00:00:00.000Z","sectionGeneration":42}}\n'
    );
    expect(events).toHaveLength(1);
    expect(events[0]?.kind).toBe("sidebarSection");
    if (events[0]?.kind === "sidebarSection") {
      expect(events[0].payload.unreadCounts?.["pub-a"]).toBe(0);
      expect(events[0].payload.replacePublicationIds).toEqual(["pub-a"]);
      expect(events[0].payload.sectionGeneration).toBe(42);
    }
  });

  it("parses unread count metadata", () => {
    const events = parseNdjsonLinesForTest(
      '{"kind":"unreadCounts","unreadCounts":{"counts":{"pub-a":3},"replacePublicationIds":["pub-a"],"generation":99,"accuracy":"exact","countedAt":"2026-01-01T00:00:00.000Z"}}\n'
    );
    expect(events).toHaveLength(1);
    expect(events[0]?.kind).toBe("unreadCounts");
    if (events[0]?.kind === "unreadCounts") {
      expect(events[0].payload.generation).toBe(99);
      expect(events[0].payload.accuracy).toBe("exact");
      expect(events[0].payload.countedAt).toBe("2026-01-01T00:00:00.000Z");
    }
  });

  it("requires and preserves entries page evidence", () => {
    const events = parseNdjsonLinesForTest(
      '{"kind":"entriesPage","entriesPage":{"publicationId":"pub-a","entries":[],"source":"projection_cache","cachedAt":"2026-01-01T00:00:00.000Z","expiresAt":"2026-01-01T00:05:00.000Z"}}\n'
    );
    expect(events).toHaveLength(1);
    expect(events[0]?.kind).toBe("entriesPage");
    if (events[0]?.kind === "entriesPage") {
      expect(events[0].payload.source).toBe("projection_cache");
      expect(events[0].payload.cachedAt).toBe("2026-01-01T00:00:00.000Z");
      expect(events[0].payload.expiresAt).toBe("2026-01-01T00:05:00.000Z");
    }

    const ungrounded = parseNdjsonLinesForTest(
      '{"kind":"entriesPage","entriesPage":{"publicationId":"pub-a","entries":[]}}\n'
    );
    expect(ungrounded).toHaveLength(0);
  });
});

describe("bootstrapStreamState", () => {
  it("merges unread counts into projection rows", () => {
    const projection = applyUnreadCountsEvent(baseProjection(), { "pub-a": 4 });
    expect(projection.subscribedUnfoldered[0]?.unreadCount).toBe(4);
    expect(projection.unreadCountsByPublicationId?.["pub-a"]).toBe(4);
  });

  it("clears stale counts when refreshing with sparse zero response", () => {
    const stale = applyUnreadCountsEvent(baseProjection(), { "pub-a": 4 });
    const refreshed = applyUnreadCountsEvent(stale, {}, {
      replacePublicationIds: ["pub-a"],
    });
    expect(refreshed.subscribedUnfoldered[0]?.unreadCount).toBe(0);
    expect(refreshed.unreadCountsByPublicationId?.["pub-a"]).toBe(0);
  });

  it("ignores older unread count generations", () => {
    const current = applyUnreadCountsEvent(
      baseProjection(),
      { "pub-a": 5 },
      {
        replacePublicationIds: ["pub-a"],
        generation: 20,
        accuracy: "estimated",
        countedAt: "2026-01-01T00:00:02.000Z",
      }
    );
    const older = applyUnreadCountsEvent(
      current,
      { "pub-a": 1 },
      {
        replacePublicationIds: ["pub-a"],
        generation: 19,
        accuracy: "exact",
        countedAt: "2026-01-01T00:00:01.000Z",
      }
    );

    expect(older).toBe(current);
    expect(older.subscribedUnfoldered[0]?.unreadCount).toBe(5);
  });

  it("lets exact counts replace equal-generation estimates", () => {
    const estimated = applyUnreadCountsEvent(
      baseProjection(),
      { "pub-a": 5 },
      {
        replacePublicationIds: ["pub-a"],
        generation: 20,
        accuracy: "estimated",
      }
    );
    const exact = applyUnreadCountsEvent(
      estimated,
      { "pub-a": 4 },
      {
        replacePublicationIds: ["pub-a"],
        generation: 20,
        accuracy: "exact",
      }
    );

    expect(exact.subscribedUnfoldered[0]?.unreadCount).toBe(4);
    expect(exact.unreadCountsAccuracy).toBe("exact");
  });

  it("uses the priority projection on cold sidebarPriority", () => {
    const next = applySidebarPriorityEvent(undefined, baseProjection());
    expect(next.subscribedUnfoldered).toHaveLength(1);
  });
});
