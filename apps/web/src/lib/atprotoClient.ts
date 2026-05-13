/**
 * Public ATProto client for reading standard.site records directly from
 * the ATProto network.
 *
 * Uses bsky.social as the relay for `com.atproto.repo.*`; authenticated
 * calls use the viewer's OAuthSession (follow graph, profile).
 */

import { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";

const BSKY_SERVICE = "https://bsky.social";

/**
 * Collections probed to decide whether a followed account has standard.site
 * content (aligned with services/api DiscoveryChain + current lexicons).
 */
export const DISCOVERY_COLLECTIONS = [
  "site.standard.document",
  "site.standard.publication",
  "site.standard.entry",
  "com.standard.publication",
] as const;

/** Preferred collection for listing posts (current ecosystem); then legacy. */
const LIST_COLLECTIONS_ORDER = [
  "site.standard.document",
  "site.standard.entry",
] as const;

/** @deprecated Use LIST_COLLECTIONS_ORDER; kept for callers expecting the legacy NSID. */
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
  /**
   * Canonical HTTPS URL for embedding the live site (record URLs, site.standard `site`+`path`, etc.).
   */
  embedUrl?: string;
  /** Linked Bluesky post — enables native like/repost/quote via ATProto. */
  bskyPostUri?: string;
  bskyPostCid?: string;
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

const LIST_CURSOR_DOC = "d:";
const LIST_CURSOR_ENT = "e:";

// ── OAuth Agent ───────────────────────────────────────────────────────────────

/**
 * OAuth-backed Agent with `did` set — required for {@link Agent.post}, {@link Agent.like}, {@link Agent.repost},
 * and {@link Agent.api}.com.atproto.repo.* against the user's **PDS** (correct token audience).
 *
 * Do **not** use this for arbitrary calls to `bsky.social`: OAuth tokens are usually scoped to the PDS,
 * and App View may reject them. Prefer `Agent` with the default Bluesky service URL and no custom fetch for public reads.
 */
export function createOAuthAgent(session: OAuthSession): Agent {
  return new Agent(session);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Parses an AT-URI into its components. */
export function parseAtUri(
  uri: string
): { did: string; collection: string; rkey: string } | null {
  const match = uri.match(/^at:\/\/([^/]+)\/([^/]+)\/([^/]+)$/);
  if (!match) return null;
  return { did: match[1], collection: match[2], rkey: match[3] };
}

function slugFromPath(path: string): string | undefined {
  const parts = path.split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : undefined;
}

/**
 * Maps a raw ATProto record value to entry fields.
 *
 * Supports `site.standard.document`, `site.standard.entry`, and related shapes.
 */
export function parseEntryValue(value: Record<string, unknown>): {
  title: string;
  publishedAt: string;
  contentHtml: string;
  originalUrl?: string;
  summary?: string;
} {
  const str = (v: unknown): string | undefined =>
    typeof v === "string" ? v : undefined;

  const pathTitle = str(value.path) ? slugFromPath(str(value.path)!) : undefined;

  return {
    title:
      str(value.title) ??
      str(value.name) ??
      pathTitle ??
      "Untitled",
    publishedAt:
      str(value.publishedAt) ??
      str(value.createdAt) ??
      str(value.indexedAt) ??
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

function extractHttpsUrl(
  ...candidates: (string | undefined)[]
): string | undefined {
  for (const c of candidates) {
    if (c && /^https?:\/\//i.test(c)) return c;
  }
  return undefined;
}

function parseStrongRef(
  v: unknown
): { uri: string; cid: string } | undefined {
  if (!v || typeof v !== "object") return undefined;
  const o = v as Record<string, unknown>;
  if (typeof o.uri === "string" && typeof o.cid === "string") {
    return { uri: o.uri, cid: o.cid };
  }
  return undefined;
}

function joinPublicationUrl(base: string, path: string): string {
  const b = base.replace(/\/+$/, "");
  const p = path.startsWith("/") ? path : `/${path}`;
  return `${b}${p}`;
}

async function resolvePublicationSiteBase(
  agent: Agent,
  siteField: string
): Promise<string | undefined> {
  if (siteField.startsWith("http://") || siteField.startsWith("https://")) {
    return siteField.replace(/\/+$/, "");
  }
  const pubUri = parseAtUri(siteField);
  if (!pubUri) return undefined;
  try {
    const rec = await agent.api.com.atproto.repo.getRecord({
      repo: pubUri.did,
      collection: pubUri.collection,
      rkey: pubUri.rkey,
    });
    const v = rec.data.value as Record<string, unknown>;
    return extractHttpsUrl(str(v.url), str(v.href), str(v.site));
  } catch {
    return undefined;
  }
}

/**
 * Resolves a canonical page URL for iframe embedding from standard.site-shaped records.
 */
async function resolveEmbedUrl(agent: Agent, value: Record<string, unknown>): Promise<string | undefined> {
  const siteField = str(value.site);
  const pathField = str(value.path);
  if (siteField && pathField) {
    if (siteField.startsWith("http://") || siteField.startsWith("https://")) {
      return joinPublicationUrl(siteField.replace(/\/+$/, ""), pathField);
    }
    if (siteField.startsWith("at://")) {
      const base = await resolvePublicationSiteBase(agent, siteField);
      if (base) return joinPublicationUrl(base, pathField);
    }
  }
  return extractHttpsUrl(
    str(value.canonicalUrl),
    str(value.href),
    str(value.permalink)
  );
}

function decodeListCursor(cursor: string | undefined):
  | "initial"
  | { kind: "document"; atproto?: string }
  | { kind: "entry"; atproto?: string } {
  if (cursor === undefined || cursor === "") return "initial";
  if (cursor.startsWith(LIST_CURSOR_DOC)) {
    const raw = cursor.slice(LIST_CURSOR_DOC.length);
    return { kind: "document", atproto: raw ? decodeURIComponent(raw) : undefined };
  }
  if (cursor.startsWith(LIST_CURSOR_ENT)) {
    const raw = cursor.slice(LIST_CURSOR_ENT.length);
    return { kind: "entry", atproto: raw ? decodeURIComponent(raw) : undefined };
  }
  // Legacy: unprefixed cursors treated as document namespace (pre-change clients).
  return { kind: "document", atproto: cursor };
}

function encodeListCursor(
  kind: "document" | "entry",
  atproto: string | undefined
): string | undefined {
  if (!atproto) return undefined;
  const enc = encodeURIComponent(atproto);
  return kind === "document" ? `${LIST_CURSOR_DOC}${enc}` : `${LIST_CURSOR_ENT}${enc}`;
}

function publicationTitleFromRecord(
  collection: string,
  value: Record<string, unknown>,
  fallback: string
): string {
  if (collection === "site.standard.publication") {
    const t = str(value.title) ?? str(value.name);
    if (t) return t;
  }
  const t = str(value.title) ?? str(value.name);
  return t ?? fallback;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Discovers followed authors with standard.site-related records.
 *
 * Uses the public Bluesky App View relay (`bsky.social`) without attaching OAuth credentials:
 * graph + repo reads are public, while OAuth tokens are audience-bound to the user's PDS.
 *
 * @param session retained for API stability; discovery does not send this token to App View.
 */
export async function discoverPublications(
  userDid: string,
  _session: OAuthSession
): Promise<DiscoveredPublication[]> {
  void _session;
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
        for (const collection of DISCOVERY_COLLECTIONS) {
          const res = await agent.api.com.atproto.repo.listRecords({
            repo: follow.did,
            collection,
            limit: 1,
          });

          if (res.data.records.length === 0) continue;

          const firstVal = res.data.records[0]!.value as Record<string, unknown>;
          const title = publicationTitleFromRecord(
            collection,
            firstVal,
            follow.displayName ?? follow.handle
          );

          return {
            publicationId: follow.did,
            authorDid: follow.did,
            authorHandle: follow.handle,
            title,
            avatarUrl: follow.avatar,
            discoveredAt,
          } satisfies DiscoveredPublication;
        }
        return null;
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
 * Lists entries for a given author DID (documents first, then legacy entries).
 * Cursors are prefixed (`d:` / `e:`) so pagination stays on one collection.
 */
export async function listEntries(
  authorDid: string,
  cursor?: string,
  limit = 50
): Promise<{ entries: EntryListItem[]; cursor?: string }> {
  const agent = new Agent(BSKY_SERVICE);
  const mode = decodeListCursor(cursor);

  if (mode === "initial") {
    const docRes = await agent.api.com.atproto.repo.listRecords({
      repo: authorDid,
      collection: LIST_COLLECTIONS_ORDER[0],
      limit,
      reverse: false,
    });

    if (docRes.data.records.length > 0) {
      const entries = docRes.data.records.map((record) => {
        const parsed = parseEntryValue(record.value as Record<string, unknown>);
        return {
          entryId: record.uri,
          title: parsed.title,
          summary: parsed.summary,
          publishedAt: parsed.publishedAt,
        };
      });
      return {
        entries,
        cursor: encodeListCursor(
          "document",
          docRes.data.cursor ?? undefined
        ),
      };
    }

    const entRes = await agent.api.com.atproto.repo.listRecords({
      repo: authorDid,
      collection: LIST_COLLECTIONS_ORDER[1],
      limit,
      reverse: false,
    });

    const entries = entRes.data.records.map((record) => {
      const parsed = parseEntryValue(record.value as Record<string, unknown>);
      return {
        entryId: record.uri,
        title: parsed.title,
        summary: parsed.summary,
        publishedAt: parsed.publishedAt,
      };
    });
    return {
      entries,
      cursor: encodeListCursor("entry", entRes.data.cursor ?? undefined),
    };
  }

  if (mode.kind === "document") {
    const docRes = await agent.api.com.atproto.repo.listRecords({
      repo: authorDid,
      collection: LIST_COLLECTIONS_ORDER[0],
      limit,
      cursor: mode.atproto,
      reverse: false,
    });
    const entries = docRes.data.records.map((record) => {
      const parsed = parseEntryValue(record.value as Record<string, unknown>);
      return {
        entryId: record.uri,
        title: parsed.title,
        summary: parsed.summary,
        publishedAt: parsed.publishedAt,
      };
    });
    return {
      entries,
      cursor: encodeListCursor("document", docRes.data.cursor ?? undefined),
    };
  }

  const entRes = await agent.api.com.atproto.repo.listRecords({
    repo: authorDid,
    collection: LIST_COLLECTIONS_ORDER[1],
    limit,
    cursor: mode.atproto,
    reverse: false,
  });
  const entries = entRes.data.records.map((record) => {
    const parsed = parseEntryValue(record.value as Record<string, unknown>);
    return {
      entryId: record.uri,
      title: parsed.title,
      summary: parsed.summary,
      publishedAt: parsed.publishedAt,
    };
  });
  return {
    entries,
    cursor: encodeListCursor("entry", entRes.data.cursor ?? undefined),
  };
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

  const raw = res.data.value as Record<string, unknown>;
  const fields = parseEntryValue(raw);

  const embedFromFields = extractHttpsUrl(fields.originalUrl);
  const embedUrl =
    embedFromFields ?? (await resolveEmbedUrl(agent, raw));

  const bskyRef = parseStrongRef(raw.bskyPostRef);

  return {
    entryId,
    title: fields.title,
    publishedAt: fields.publishedAt,
    contentHtml: fields.contentHtml,
    originalUrl: fields.originalUrl,
    embedUrl,
    bskyPostUri: bskyRef?.uri,
    bskyPostCid: bskyRef?.cid,
  };
}
