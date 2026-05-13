/**
 * Public ATProto client for reading standard.site entries directly from
 * the ATProto network.
 *
 * No authentication is required — entry records are public. Uses bsky.social
 * as the service endpoint; it acts as a relay and serves com.atproto.repo.*
 * requests for all DID:PLC users across the network.
 */

import { Agent } from "@atproto/api";

const BSKY_SERVICE = "https://bsky.social";

/** Collection identifier for standard.site entries. */
export const ENTRY_COLLECTION = "site.standard.entry";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface DiscoveredPublication {
  /** The author's DID — used as the stable publication identifier. */
  publicationId: string;
  authorDid: string;
  authorHandle: string;
  title: string;
  avatarUrl?: string;
  discoveredAt: string;
}

export interface EntryListItem {
  /** AT-URI of the entry record. */
  entryId: string;
  title: string;
  summary?: string;
  publishedAt: string;
}

export interface EntryDetail {
  entryId: string;
  title: string;
  publishedAt: string;
  /** Full entry content as HTML. May be empty if the record stores markdown or a blob. */
  contentHtml: string;
  originalUrl?: string;
}

interface FollowProfile {
  did: string;
  handle: string;
  displayName?: string;
  avatar?: string;
}

const MAX_FOLLOWS = 500;
const FOLLOW_PAGE_LIMIT = 100;
const DISCOVERY_BATCH_SIZE = 25;

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Parses an AT-URI into its components. */
export function parseAtUri(
  uri: string
): { did: string; collection: string; rkey: string } | null {
  const match = uri.match(/^at:\/\/([^/]+)\/([^/]+)\/([^/]+)$/);
  if (!match) return null;
  return { did: match[1], collection: match[2], rkey: match[3] };
}

/**
 * Maps a raw ATProto record value to entry fields.
 *
 * standard.site's exact schema isn't pinned here — we try the most likely
 * field names in order so the client degrades gracefully as the lexicon evolves.
 */
function parseEntryValue(value: Record<string, unknown>): {
  title: string;
  publishedAt: string;
  contentHtml: string;
  originalUrl?: string;
  summary?: string;
} {
  const str = (v: unknown): string | undefined =>
    typeof v === "string" ? v : undefined;

  return {
    title: str(value.title) ?? str(value.name) ?? "Untitled",
    publishedAt:
      str(value.publishedAt) ??
      str(value.createdAt) ??
      new Date().toISOString(),
    contentHtml:
      str(value.content) ??
      str(value.contentHtml) ??
      str(value.text) ??
      str(value.body) ??
      "",
    originalUrl: str(value.url) ?? str(value.externalUrl),
    summary: str(value.summary) ?? str(value.description),
  };
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Discovers followed authors with standard.site entries.
 * Fetches directly from public ATProto XRPC endpoints — no Social Wire service
 * or Next.js API route required.
 */
export async function discoverPublications(
  userDid: string
): Promise<DiscoveredPublication[]> {
  const agent = new Agent(BSKY_SERVICE);
  const follows: FollowProfile[] = [];

  let cursor: string | undefined;
  do {
    const res = await agent.api.app.bsky.graph.getFollows({
      actor: userDid,
      limit: FOLLOW_PAGE_LIMIT,
      cursor,
    });

    for (const follow of res.data.follows) {
      follows.push({
        did: follow.did,
        handle: follow.handle,
        displayName: follow.displayName,
        avatar: follow.avatar,
      });
    }

    cursor = res.data.cursor;
  } while (cursor && follows.length < MAX_FOLLOWS);

  const publications: DiscoveredPublication[] = [];
  const discoveredAt = new Date().toISOString();

  for (let i = 0; i < follows.length; i += DISCOVERY_BATCH_SIZE) {
    const batch = follows.slice(i, i + DISCOVERY_BATCH_SIZE);
    const results = await Promise.allSettled(
      batch.map(async (follow) => {
        const res = await agent.api.com.atproto.repo.listRecords({
          repo: follow.did,
          collection: ENTRY_COLLECTION,
          limit: 1,
        });

        if (res.data.records.length === 0) return null;

        return {
          publicationId: follow.did,
          authorDid: follow.did,
          authorHandle: follow.handle,
          title: follow.displayName ?? follow.handle,
          avatarUrl: follow.avatar,
          discoveredAt,
        } satisfies DiscoveredPublication;
      })
    );

    for (const result of results) {
      if (result.status === "fulfilled" && result.value !== null) {
        publications.push(result.value);
      }
    }
  }

  return publications;
}

/**
 * Lists entries for a given author DID, newest first.
 * Fetches directly from the ATProto network — no Social Wire service needed.
 */
export async function listEntries(
  authorDid: string,
  cursor?: string,
  limit = 50
): Promise<{ entries: EntryListItem[]; cursor?: string }> {
  const agent = new Agent(BSKY_SERVICE);
  const res = await agent.api.com.atproto.repo.listRecords({
    repo: authorDid,
    collection: ENTRY_COLLECTION,
    limit,
    cursor,
    reverse: false,
  });

  const entries: EntryListItem[] = res.data.records.map((record) => {
    const parsed = parseEntryValue(record.value as Record<string, unknown>);
    return {
      entryId: record.uri,
      title: parsed.title,
      summary: parsed.summary,
      publishedAt: parsed.publishedAt,
    };
  });

  return { entries, cursor: res.data.cursor ?? undefined };
}

/**
 * Fetches the full content for a single entry by its AT-URI.
 */
export async function getEntry(entryId: string): Promise<EntryDetail | null> {
  const parsed = parseAtUri(entryId);
  if (!parsed) return null;

  const agent = new Agent(BSKY_SERVICE);
  const res = await agent.api.com.atproto.repo.getRecord({
    repo: parsed.did,
    collection: parsed.collection,
    rkey: parsed.rkey,
  });

  const fields = parseEntryValue(res.data.value as Record<string, unknown>);
  return {
    entryId,
    title: fields.title,
    publishedAt: fields.publishedAt,
    contentHtml: fields.contentHtml,
    originalUrl: fields.originalUrl,
  };
}
