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

/** Follow edges stored on the viewer's repo (canonical over Bluesky relay mirrors). */
const GRAPH_FOLLOW_COLLECTION = "app.bsky.graph.follow";

async function resolvePlcPdsEndpoint(did: string): Promise<string | null> {
  if (!did.startsWith("did:plc:")) return null;
  try {
    const res = await fetch(
      `https://plc.directory/${encodeURIComponent(did)}`,
      { headers: { Accept: "application/json" } }
    );
    if (!res.ok) return null;
    const doc = (await res.json()) as {
      service?: Array<{ type?: string; serviceEndpoint?: string }>;
    };
    const endpoint = doc.service?.find(
      (s) => s.type === "AtprotoPersonalDataServer"
    )?.serviceEndpoint;
    return typeof endpoint === "string" ? endpoint.replace(/\/$/, "") : null;
  } catch {
    return null;
  }
}

/** Repo reads via author's PDS when the App View relay returns nothing (indexing gaps). */
async function listRecordsDirectFromPds(
  pdsBase: string,
  repo: string,
  collection: string,
  limit: number
): Promise<{ uri: string; value: unknown }[]> {
  const params = new URLSearchParams({
    repo,
    collection,
    limit: String(limit),
  });
  try {
    const res = await fetch(
      `${pdsBase}/xrpc/com.atproto.repo.listRecords?${params}`,
      { headers: { Accept: "application/json" } }
    );
    if (!res.ok) return [];
    const json = (await res.json()) as {
      records?: Array<{ uri: string; value: unknown }>;
    };
    return json.records ?? [];
  } catch {
    return [];
  }
}

async function enrichFollowsFromRelay(
  relayAgent: Agent,
  follows: FollowProfile[]
): Promise<void> {
  const chunkSize = 12;
  for (let i = 0; i < follows.length; i += chunkSize) {
    const slice = follows.slice(i, i + chunkSize);
    await Promise.all(
      slice.map(async (f) => {
        try {
          const res = await relayAgent.api.app.bsky.actor.getProfile({
            actor: f.did,
          });
          const p = res.data;
          f.handle = p.handle;
          f.displayName = p.displayName ?? undefined;
          f.avatar = p.avatar ?? undefined;
        } catch {
          /* DID may not be indexed on Bluesky — keep DID-shaped handle */
        }
      })
    );
  }
}

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
 * Follow subjects come from:
 * - **`app.bsky.graph.follow`** on the viewer's repo (OAuth / PDS — canonical graph).
 * - **`app.bsky.graph.getFollows`** on the Bluesky relay (additional mirrored edges).
 *
 * Each followed repo is checked via the relay first; if empty, **`listRecords`** against the
 * author's **PDS** (PLC-resolved) catches relay indexing gaps.
 */
export async function discoverPublications(
  userDid: string,
  session: OAuthSession
): Promise<DiscoveredPublication[]> {
  const relayAgent = new Agent(BSKY_SERVICE);
  const pdsAgent = createOAuthAgent(session);

  const subjectDids = new Set<string>();

  try {
    let cursor: string | undefined;
    do {
      const res = await pdsAgent.api.com.atproto.repo.listRecords({
        repo: userDid,
        collection: GRAPH_FOLLOW_COLLECTION,
        limit: FOLLOW_PAGE_LIMIT,
        cursor,
      });
      for (const record of res.data.records) {
        const val = record.value as { subject?: string };
        if (typeof val.subject === "string") subjectDids.add(val.subject);
        if (subjectDids.size >= MAX_FOLLOWS) break;
      }
      cursor = res.data.cursor;
      if (subjectDids.size >= MAX_FOLLOWS) break;
    } while (cursor);
  } catch {
    /* unreadable repo graph — merge relay-only below */
  }

  if (subjectDids.size < MAX_FOLLOWS) {
    try {
      let cursor: string | undefined;
      do {
        const res = await relayAgent.api.app.bsky.graph.getFollows({
          actor: userDid,
          limit: FOLLOW_PAGE_LIMIT,
          cursor,
        });
        for (const follow of res.data.follows) {
          subjectDids.add(follow.did);
          if (subjectDids.size >= MAX_FOLLOWS) break;
        }
        cursor = res.data.cursor;
        if (subjectDids.size >= MAX_FOLLOWS) break;
      } while (cursor);
    } catch {
      /* relay unavailable */
    }
  }

  const follows: FollowProfile[] = [...subjectDids]
    .slice(0, MAX_FOLLOWS)
    .map((did) => ({
      did,
      handle: did,
      displayName: undefined,
      avatar: undefined,
    }));

  await enrichFollowsFromRelay(relayAgent, follows);

  const publications: DiscoveredPublication[] = [];
  const discoveredAt = new Date().toISOString();

  async function probeFollow(
    follow: FollowProfile
  ): Promise<DiscoveredPublication | null> {
    for (const collection of DISCOVERY_COLLECTIONS) {
      let rows: Array<{ value: unknown }> = [];
      try {
        const relayRes = await relayAgent.api.com.atproto.repo.listRecords({
          repo: follow.did,
          collection,
          limit: 1,
        });
        rows = relayRes.data.records;
      } catch {
        rows = [];
      }

      if (rows.length === 0) {
        const pds = await resolvePlcPdsEndpoint(follow.did);
        if (pds) {
          const direct = await listRecordsDirectFromPds(
            pds,
            follow.did,
            collection,
            1
          );
          if (direct.length > 0) rows = direct;
        }
      }

      if (rows.length === 0) continue;

      const firstVal = rows[0]!.value as Record<string, unknown>;
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
      };
    }
    return null;
  }

  for (let i = 0; i < follows.length; i += DISCOVERY_BATCH_SIZE) {
    const batch = follows.slice(i, i + DISCOVERY_BATCH_SIZE);
    const results = await Promise.allSettled(
      batch.map((follow) => probeFollow(follow))
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
