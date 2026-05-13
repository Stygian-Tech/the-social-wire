/**
 * MSW handlers for ATProto network calls.
 *
 * bsky.social    — ATProto relay used by atprotoClient.ts
 */

import { http, HttpResponse } from "msw";
import type { DiscoveredPublication, EntryListItem, EntryDetail } from "@/lib/atprotoClient";

// ── Fixture data ──────────────────────────────────────────────────────────────

export const MOCK_PUBLICATIONS: DiscoveredPublication[] = [
  {
    publicationId: "did:plc:alice",
    authorDid: "did:plc:alice",
    authorHandle: "alice.bsky.social",
    title: "Alice's Tech Blog",
    avatarUrl: undefined,
    discoveredAt: "2025-01-01T00:00:00Z",
  },
  {
    publicationId: "did:plc:bob",
    authorDid: "did:plc:bob",
    authorHandle: "bob.bsky.social",
    title: "Bob's News",
    avatarUrl: "https://cdn.bsky.app/img/avatar/bob.jpg",
    discoveredAt: "2025-01-02T00:00:00Z",
  },
];

export const MOCK_ENTRIES: EntryListItem[] = [
  {
    entryId: "at://did:plc:alice/site.standard.entry/entry1",
    title: "First Post",
    summary: "This is the first post summary.",
    publishedAt: "2025-01-10T12:00:00Z",
  },
  {
    entryId: "at://did:plc:alice/site.standard.entry/entry2",
    title: "Second Post",
    summary: "Another great post.",
    publishedAt: "2025-01-11T12:00:00Z",
  },
];

export const MOCK_ENTRY_DETAIL: EntryDetail = {
  entryId: "at://did:plc:alice/site.standard.entry/entry1",
  title: "First Post",
  publishedAt: "2025-01-10T12:00:00Z",
  contentHtml: "<p>Hello <strong>world</strong>!</p>",
  originalUrl: "https://alice.example.com/posts/first",
};

// ── Handlers ──────────────────────────────────────────────────────────────────

export const serviceHandlers = [
  // ATProto relay — list records (used by listEntries)
  http.get("https://bsky.social/xrpc/com.atproto.repo.listRecords", ({ request }) => {
    const url = new URL(request.url);
    const collection = url.searchParams.get("collection");
    if (collection !== "site.standard.entry") {
      return HttpResponse.json({ records: [], cursor: undefined });
    }
    return HttpResponse.json({
      records: MOCK_ENTRIES.map((e) => ({
        uri: e.entryId,
        cid: `cid-${e.entryId}`,
        value: {
          $type: "site.standard.entry",
          title: e.title,
          summary: e.summary,
          publishedAt: e.publishedAt,
          content: "",
        },
      })),
      cursor: undefined,
    });
  }),

  // ATProto relay — get record (used by getEntry)
  http.get("https://bsky.social/xrpc/com.atproto.repo.getRecord", ({ request }) => {
    const url = new URL(request.url);
    const rkey = url.searchParams.get("rkey");
    const entry = MOCK_ENTRIES.find((e) => e.entryId.endsWith(`/${rkey}`));
    if (!entry) {
      return HttpResponse.json({ error: "RecordNotFound" }, { status: 400 });
    }
    return HttpResponse.json({
      uri: MOCK_ENTRY_DETAIL.entryId,
      cid: `cid-${MOCK_ENTRY_DETAIL.entryId}`,
      value: {
        $type: "site.standard.entry",
        title: MOCK_ENTRY_DETAIL.title,
        publishedAt: MOCK_ENTRY_DETAIL.publishedAt,
        content: MOCK_ENTRY_DETAIL.contentHtml,
        url: MOCK_ENTRY_DETAIL.originalUrl,
      },
    });
  }),
];
