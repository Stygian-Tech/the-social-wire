/**
 * Public ATProto client for reading standard.site records directly from
 * authors' PDS endpoints (PLC-resolved). Bluesky App View often returns 400 for
 * `com.atproto.repo.*` on `site.standard.*` collections — do not rely on it for repo reads.
 */

import { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";

import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";

/**
 * Public App View — identity (`resolveHandle`), graph, profile (`getProfile`).
 * Prefer this host over `bsky.social` for unauthenticated browser reads.
 */
export const BSKY_APPVIEW_PUBLIC = "https://public.api.bsky.app";

/**
 * Publication-shaped collections — probed first so the sidebar shows site/publication
 * names, not individual article titles (see {@link discoverPublications}).
 */
const DISCOVERY_PUBLICATION_COLLECTIONS = [
  "site.standard.publication",
  "com.standard.publication",
] as const;

/**
 * Post/document collections — only used when the author has no publication record but does
 * have standard.site posts; sidebar label stays the author/handle, not one article title.
 */
const DISCOVERY_CONTENT_COLLECTIONS = [
  "site.standard.document",
  "com.standard.document",
  "site.standard.entry",
  "com.standard.entry",
] as const;

/** Union of collections probed during discovery (publication lexicons first). */
export const DISCOVERY_COLLECTIONS = [
  ...DISCOVERY_PUBLICATION_COLLECTIONS,
  ...DISCOVERY_CONTENT_COLLECTIONS,
] as const;

/**
 * Post/document collections — same order as discovery probes for content, plus `com.standard.*`
 * mirrors. Listing must cover every collection discovery can use or the sidebar shows a pub with
 * no articles.
 */
const LIST_COLLECTIONS_ORDER = [
  "site.standard.document",
  "com.standard.document",
  "site.standard.entry",
  "com.standard.entry",
] as const;

/** @deprecated Use LIST_COLLECTIONS_ORDER; kept for callers expecting the legacy NSID. */
export const ENTRY_COLLECTION = "site.standard.entry";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface DiscoveredPublication {
  /**
   * Stable publication key: the author's DID when discovery inferred a single feed for that
   * repo, or a **`site.standard.publication` / `com.standard.publication` record AT-URI**
   * when listing distinct publication records (e.g. multiple pubs on the same account).
   */
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
  /**
   * Resolved image URL for list row (typically `site.standard.document` `coverImage` blob → PDS
   * `com.atproto.sync.getBlob`, or HTTPS field fallbacks).
   */
  thumbnailUrl?: string;
  /**
   * When {@link thumbnailUrl} is a blob/sync URL and the record also declares HTTPS thumbnails,
   * this is wired for `<img onError>` retry paths in the sidebar.
   */
  thumbnailFallbackUrl?: string;
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
const OWN_PUBLICATIONS_PAGE_LIMIT = 50;

/** Collections whose record AT-URIs may be used as {@link DiscoveredPublication.publicationId}. */
export const PUBLICATION_RECORD_COLLECTIONS = new Set<string>([
  "site.standard.publication",
  "com.standard.publication",
]);

const LIST_CURSOR_DOC = "d:";
const LIST_CURSOR_ENT = "e:";

/** Follow edges stored on the viewer's repo (canonical over Bluesky relay mirrors). */
const GRAPH_FOLLOW_COLLECTION = "app.bsky.graph.follow";

const plcEndpointCache = new Map<string, string | null>();

/** In-flight PLC resolution so concurrent list/thumbnail lookups share one network round-trip. */
const plcEndpointInflight = new Map<string, Promise<string | null>>();

/**
 * Some PLC `#atproto_pds` endpoints (notably Bridgy Fed relay) answer `com.atproto.repo.listRecords`
 * but reject **`reverse=true`** with HTTP 400 — the param is valid per the lexicon on full PDSes.
 * For those hosts we list ascending and {@link sortRepoRecordsNewestFirst} each page.
 */
function relayHostOmitsListRecordsReverse(pdsBase: string): boolean {
  try {
    const host = new URL(pdsBase).hostname.toLowerCase();
    return host === "atproto.brid.gy" || host.endsWith(".brid.gy");
  } catch {
    return false;
  }
}

/** Stable newest-first order for raw `listRecords` rows (matches {@link sortEntryListItemsNewestFirst}). */
function sortRepoRecordsNewestFirst(
  records: Array<{ uri: string; value: unknown }>
): Array<{ uri: string; value: unknown }> {
  return [...records].sort((a, b) => {
    const ta = parseEntryValue(a.value as Record<string, unknown>).publishedAt;
    const tb = parseEntryValue(b.value as Record<string, unknown>).publishedAt;
    const byTime = tb.localeCompare(ta);
    if (byTime !== 0) return byTime;
    return a.uri.localeCompare(b.uri);
  });
}

async function plcPdsBaseForRepoDid(repoDid: string): Promise<string | null> {
  if (!repoDid.startsWith("did:")) return null;
  const cached = plcEndpointCache.get(repoDid);
  if (cached !== undefined) return cached;

  let inflight = plcEndpointInflight.get(repoDid);
  if (!inflight) {
    inflight = (async () => {
      const endpoint = await resolvePlcPdsEndpoint(repoDid);
      plcEndpointCache.set(repoDid, endpoint);
      return endpoint;
    })().finally(() => {
      plcEndpointInflight.delete(repoDid);
    });
    plcEndpointInflight.set(repoDid, inflight);
  }
  return inflight;
}

/** Cache handle → DID for {@link resolveRepoDid} (App View resolveHandle). */
const handleToDidCache = new Map<string, string>();

/**
 * `repo` parameters must be a DID for PLC/PDS reads. Handles are resolved via public App View.
 */
async function resolveRepoDid(handleOrDid: string): Promise<string | null> {
  const trimmed = normalizeAtRepoParam(handleOrDid);
  if (!trimmed) return null;
  if (trimmed.startsWith("did:")) return trimmed;

  const cached = handleToDidCache.get(trimmed);
  if (cached) return cached;

  try {
    const params = new URLSearchParams({ handle: trimmed });
    const url = `${BSKY_APPVIEW_PUBLIC}/xrpc/com.atproto.identity.resolveHandle?${params}`;
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const json = (await res.json()) as { did?: string };
    const did = typeof json.did === "string" ? json.did : null;
    if (did) handleToDidCache.set(trimmed, did);
    return did;
  } catch {
    return null;
  }
}

async function resolvePlcPdsEndpoint(did: string): Promise<string | null> {
  if (!did.startsWith("did:")) return null;
  try {
    const url = `https://plc.directory/${encodeURIComponent(did)}`;
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) return null;
    const doc = (await res.json()) as {
      service?: Array<{
        id?: string;
        type?: string;
        serviceEndpoint?: unknown;
      }>;
    };
    for (const s of doc.service ?? []) {
      const ep = s.serviceEndpoint;
      if (
        typeof ep === "string" &&
        (s.id === "#atproto_pds" || s.type === "AtprotoPersonalDataServer")
      ) {
        const trimmed = ep.replace(/\/+$/, "");
        return normalizeHttpUrlToHttps(trimmed);
      }
    }
    return null;
  } catch {
    return null;
  }
}

function oauthAwareFetch(session: OAuthSession | undefined) {
  if (!session) return undefined;
  return (url: string, init?: RequestInit) =>
    session.fetchHandler(url, init as RequestInit);
}

/**
 * Reads `listRecords` from the repo DID's **own** PDS (PLC). Optionally retries with OAuth
 * when the host returns 400/401/403 (some PDS policies require an authenticated session).
 */
async function listRecordsOnAuthorRepo(
  repoDidOrHandle: string,
  collection: string,
  options: { limit: number; cursor?: string; reverse?: boolean; signal?: AbortSignal },
  oauthSession?: OAuthSession
): Promise<{
  records: Array<{ uri: string; value: unknown }>;
  cursor?: string;
}> {
  const repoDid = await resolveRepoDid(repoDidOrHandle);
  if (!repoDid) return { records: [] };

  const pdsBase = await plcPdsBaseForRepoDid(repoDid);
  if (!pdsBase) return { records: [] };

  const wantReverse = options.reverse ?? false;
  const serverReverse =
    wantReverse && relayHostOmitsListRecordsReverse(pdsBase)
      ? false
      : wantReverse;
  const sortPageNewestFirst =
    wantReverse && serverReverse !== wantReverse;

  const params = new URLSearchParams({
    repo: repoDid,
    collection,
    limit: String(options.limit),
    reverse: String(serverReverse),
  });
  if (options.cursor) params.set("cursor", options.cursor);

  const url = `${pdsBase}/xrpc/com.atproto.repo.listRecords?${params}`;
  const init: RequestInit = {
    headers: { Accept: "application/json" },
    signal: options.signal,
  };

  let res = await fetch(url, init);
  const authed = oauthAwareFetch(oauthSession);
  if (
    !res.ok &&
    authed &&
    (res.status === 400 || res.status === 401 || res.status === 403)
  ) {
    res = await authed(url, init);
  }
  if (!res.ok) return { records: [] };

  const json = (await res.json()) as {
    records?: Array<{ uri: string; value: unknown }>;
    cursor?: string;
  };
  const rows = json.records ?? [];
  return {
    records: sortPageNewestFirst ? sortRepoRecordsNewestFirst(rows) : rows,
    cursor: json.cursor,
  };
}

async function getRecordOnAuthorRepo(
  repoDidOrHandle: string,
  collection: string,
  rkey: string,
  oauthSession?: OAuthSession
): Promise<unknown | null> {
  const repo = await resolveRepoDid(repoDidOrHandle);
  if (!repo) return null;

  const pdsBase = await plcPdsBaseForRepoDid(repo);
  if (!pdsBase) return null;

  const params = new URLSearchParams({ repo, collection, rkey });
  const url = `${pdsBase}/xrpc/com.atproto.repo.getRecord?${params}`;
  const init: RequestInit = { headers: { Accept: "application/json" } };

  let res = await fetch(url, init);
  const authed = oauthAwareFetch(oauthSession);
  if (
    !res.ok &&
    authed &&
    (res.status === 400 || res.status === 401 || res.status === 403)
  ) {
    res = await authed(url, init);
  }
  if (!res.ok) return null;

  const json = (await res.json()) as { value?: unknown };
  return json.value ?? null;
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
 * and `com.atproto.repo.*` XRPC against the user's **PDS** (correct token audience).
 *
 * Do **not** use this for arbitrary calls to `bsky.social`: OAuth tokens are usually scoped to the PDS,
 * and App View may reject them. Prefer {@link createPublicAppViewAgent} (or `new Agent(BSKY_APPVIEW_PUBLIC)`)
 * for `app.bsky.*` reads that must not use the PDS-bound OAuth `fetchHandler`.
 */
export function createOAuthAgent(session: OAuthSession): Agent {
  return new Agent(session);
}

/** Unauthenticated App View — use for `app.bsky.*` lexicons (e.g. `getPosts`) that must not hit the user PDS. */
export function createPublicAppViewAgent(): Agent {
  return new Agent(BSKY_APPVIEW_PUBLIC);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const AT_URI_PATH_RE = /^at:\/\/([^/]+)\/([^/]+)\/([^/]+)$/;

/**
 * Decodes `encodeURIComponent` layers on a single path segment (e.g. did or NSID), but
 * never touches the **`rkey`** segment of a full AT-URI.
 */
function decodeUriEncodingLayers(segment: string): string {
  let s = segment;
  for (let i = 0; i < 3; i++) {
    if (!s.includes("%")) break;
    try {
      const next = decodeURIComponent(s);
      if (next === s) break;
      s = next;
    } catch {
      break;
    }
  }
  return s;
}

/**
 * For `at://…` only: decodes percent-escapes in the **authority** and **collection**
 * segments so `at://did%3Aplc%3Ax/site.standard.publication/rkey` becomes a repo DID
 * `listRecords` can use — without applying `decodeURIComponent` to the **rkey** (which
 * must stay verbatim e.g. `foo%3Abar`).
 */
function decodeAtUriAuthorityAndCollection(s: string): string {
  const m = s.match(AT_URI_PATH_RE);
  if (!m) return s;
  const [, auth, coll, rkey] = m;
  const na = decodeUriEncodingLayers(auth);
  const nc = decodeUriEncodingLayers(coll);
  if (na === auth && nc === coll) return s;
  return `at://${na}/${nc}/${rkey}`;
}

/**
 * Normalizes a sidebar or route `repo`-style value: trim, strip a leading `@`, then
 * apply up to three `decodeURIComponent` passes while each pass changes the string so
 * DIDs and `at://` URIs survive URL segments (`encodeURIComponent`), including accidental
 * double-encoding (`did%253A…`).
 *
 * When the value is already shaped like `at://repo/collection/rkey`, percent-decoding
 * is applied only to **repo** and **collection**, not **rkey** (so rkeys stay stable).
 * Standalone DIDs and not-yet-parsed strings still use full-string decoding passes.
 */
export function normalizeAtRepoParam(raw: string): string {
  let s = raw.trim().replace(/^@/, "");
  for (let i = 0; i < 3; i++) {
    if (s.startsWith("did:")) {
      return s;
    }
    if (AT_URI_PATH_RE.test(s)) {
      const next = decodeAtUriAuthorityAndCollection(s);
      if (next !== s) {
        s = next;
        continue;
      }
      return s;
    }
    const prev = s;
    try {
      const decoded = decodeURIComponent(prev);
      if (decoded === prev) break;
      s = decoded;
    } catch {
      break;
    }
  }
  return s;
}

/**
 * Publication key from the Next.js `read/[...pubId]` catch-all segments.
 *
 * AT-URI publication ids are routed as `router.push(`/read/${encodeURIComponent(uri)}`)`. If `%2F`
 * is decoded into real path slashes (browser, CDN, reverse proxy), a single `@pubId` param no
 * longer matches and Next returns **404**. Joining segment arrays restores `at://…/collection/rkey`
 * (`["at:", "", "did:plc:x", …].join("/")` → correct `//` after `at:`).
 */
export function readRoutePubIdFromSegments(pubId: string | string[]): string {
  const raw = Array.isArray(pubId)
    ? pubId.length === 0
      ? ""
      : pubId.join("/")
    : pubId;
  return normalizeAtRepoParam(raw);
}

/** Parses an AT-URI into its components. */
export function parseAtUri(
  uri: string
): { did: string; collection: string; rkey: string } | null {
  const normalized = normalizeAtRepoParam(uri);
  const match = normalized.match(AT_URI_PATH_RE);
  if (!match) return null;
  return { did: match[1], collection: match[2], rkey: match[3] };
}

/**
 * Decodes repo-style encoding (URL segments, `@`) and normalizes **`did:plc:`** to lowercase
 * so OAuth `session.did` matches publication AT-URI authorities from the PDS.
 */
export function normalizeDidForOwnershipCompare(raw: string): string {
  const n = normalizeAtRepoParam(raw);
  if (n.toLowerCase().startsWith("did:plc:")) return n.toLowerCase();
  return n;
}

/**
 * Maps a sidebar / route `pubId` to the repo DID for `listRecords`, and optionally the publication
 * record AT-URI for filtering document/entry `site` to that publication.
 */
export function repoAndPublicationFilterFromPubId(pubId: string): {
  repoDid: string;
  publicationAtUri?: string;
} {
  const normalized = normalizeAtRepoParam(pubId);
  const parsed = parseAtUri(normalized);
  if (parsed && PUBLICATION_RECORD_COLLECTIONS.has(parsed.collection)) {
    return { repoDid: parsed.did, publicationAtUri: normalized };
  }
  return { repoDid: normalized };
}

/**
 * Repo DID that owns this sidebar publication key (aggregate `did:…` id or a publication AT-URI).
 * When {@link repoAndPublicationFilterFromPubId} falls back to a non-publication AT-URI string,
 * this still extracts the embedded DID.
 */
export function publicationRepoDid(pubId: string): string {
  let { repoDid } = repoAndPublicationFilterFromPubId(pubId);
  const parsedRepo = parseAtUri(repoDid);
  if (parsedRepo?.did) return parsedRepo.did;
  return repoDid;
}

/** True if this discovered publication should appear only under "My Publications", not "All". */
export function viewerOwnsDiscoveredPublication(
  publication: { publicationId: string; authorDid?: string },
  viewerDid: string | null | undefined
): boolean {
  if (!viewerDid) return false;
  const v = normalizeDidForOwnershipCompare(viewerDid);
  const fromPubId = normalizeDidForOwnershipCompare(
    publicationRepoDid(publication.publicationId)
  );
  if (fromPubId === v) return true;

  const author = publication.authorDid;
  if (author && normalizeDidForOwnershipCompare(author) === v) return true;

  return false;
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

function str(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

/** Blob reference shape on records (`coverImage`, etc.). */
function extractBlobLink(obj: unknown): string | undefined {
  if (!obj || typeof obj !== "object") return undefined;
  const o = obj as Record<string, unknown>;
  if (typeof o["$link"] === "string") return o["$link"];
  const ref = o.ref;
  if (ref && typeof ref === "object") {
    const link = (ref as Record<string, unknown>)["$link"];
    if (typeof link === "string") return link;
  }
  return undefined;
}

/** HTTPS-ish thumbnail URLs only — used after blob/sync primary for `<img onError>` recovery. */
function extractHttpsThumbnailOnly(value: Record<string, unknown>): string | undefined {
  const cover = value.coverImage;
  if (typeof cover === "string") {
    const url = extractHttpsUrl(cover);
    if (url) return normalizeHttpUrlToHttps(url);
  }
  const thumb = value.thumbnail;
  if (typeof thumb === "string") {
    const url = extractHttpsUrl(thumb);
    if (url) return normalizeHttpUrlToHttps(url);
  }
  const ext = extractHttpsUrl(
    str(value.thumbnailUrl),
    str(value.coverImageUrl),
    str(value.image),
    str(value.heroImage),
    str(value.socialImage)
  );
  return ext ? normalizeHttpUrlToHttps(ext) : undefined;
}

type ThumbnailCandidate =
  | { kind: "blob"; cid: string }
  | { kind: "https"; url: string };

function thumbnailCandidateFromRecordValue(
  value: Record<string, unknown>
): ThumbnailCandidate | undefined {
  const cover = value.coverImage;
  if (typeof cover === "string") {
    const url = extractHttpsUrl(cover);
    if (url) return { kind: "https", url };
  }
  const coverCid = cover ? extractBlobLink(cover) : undefined;
  if (coverCid) return { kind: "blob", cid: coverCid };

  const thumb = value.thumbnail;
  if (typeof thumb === "string") {
    const url = extractHttpsUrl(thumb);
    if (url) return { kind: "https", url };
  }
  const thumbCid = thumb ? extractBlobLink(thumb) : undefined;
  if (thumbCid) return { kind: "blob", cid: thumbCid };

  const ext = extractHttpsUrl(
    str(value.thumbnailUrl),
    str(value.coverImageUrl),
    str(value.image),
    str(value.heroImage),
    str(value.socialImage)
  );
  if (ext) return { kind: "https", url: ext };

  return undefined;
}

export type ResolvedEntryThumbnail = {
  thumbnailUrl?: string;
  thumbnailFallbackUrl?: string;
};

/**
 * Resolves primary + optional HTTPS fallback for sidebar thumbnails (blob via canonical repo DID
 * and PLC PDS, same as repo reads — handle AT-URI authorities are resolved via App View).
 */
export async function resolveEntryThumbnailUrls(
  entryUri: string,
  value: unknown,
  _oauthSession?: OAuthSession
): Promise<ResolvedEntryThumbnail> {
  void _oauthSession;
  if (!value || typeof value !== "object") return {};

  const record = value as Record<string, unknown>;
  const candidate = thumbnailCandidateFromRecordValue(record);
  if (!candidate) return {};

  if (candidate.kind === "https") {
    return { thumbnailUrl: normalizeHttpUrlToHttps(candidate.url) };
  }

  const parsed = parseAtUri(entryUri);
  if (!parsed) return {};

  const repoDid = await resolveRepoDid(parsed.did);
  if (!repoDid?.startsWith("did:")) return {};

  const pdsRaw = await plcPdsBaseForRepoDid(repoDid);
  if (!pdsRaw) return {};

  const pds = normalizeHttpUrlToHttps(pdsRaw);

  const httpsFallback =
    candidate.kind === "blob" ? extractHttpsThumbnailOnly(record) : undefined;
  const params = new URLSearchParams({
    did: repoDid,
    cid: candidate.cid,
  });
  const blobUrl = `${pds}/xrpc/com.atproto.sync.getBlob?${params}`;

  return {
    thumbnailUrl: blobUrl,
    ...(httpsFallback && httpsFallback !== blobUrl
      ? { thumbnailFallbackUrl: httpsFallback }
      : {}),
  };
}

/**
 * Resolves a usable `<img src>` URL for entry list rows from record fields (blob preferred per
 * `site.standard.document#coverImage`, then common HTTPS metadata).
 */
export async function resolveEntryThumbnailUrl(
  entryUri: string,
  value: unknown,
  oauthSession?: OAuthSession
): Promise<string | undefined> {
  const r = await resolveEntryThumbnailUrls(entryUri, value, oauthSession);
  return r.thumbnailUrl;
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
  siteField: string,
  oauthSession?: OAuthSession
): Promise<string | undefined> {
  if (siteField.startsWith("http://") || siteField.startsWith("https://")) {
    return siteField.replace(/\/+$/, "");
  }
  const pubUri = parseAtUri(siteField);
  if (!pubUri) return undefined;
  const val = await getRecordOnAuthorRepo(
    pubUri.did,
    pubUri.collection,
    pubUri.rkey,
    oauthSession
  );
  if (!val || typeof val !== "object") return undefined;
  const v = val as Record<string, unknown>;
  return extractHttpsUrl(str(v.url), str(v.href), str(v.site));
}

/**
 * Resolves a canonical page URL for iframe embedding from standard.site-shaped records.
 */
async function resolveEmbedUrl(
  value: Record<string, unknown>,
  oauthSession?: OAuthSession
): Promise<string | undefined> {
  const siteField = str(value.site);
  const pathField = str(value.path);
  if (siteField && pathField) {
    if (siteField.startsWith("http://") || siteField.startsWith("https://")) {
      return joinPublicationUrl(siteField.replace(/\/+$/, ""), pathField);
    }
    if (siteField.startsWith("at://")) {
      const base = await resolvePublicationSiteBase(siteField, oauthSession);
      if (base) return joinPublicationUrl(base, pathField);
    }
  }
  return extractHttpsUrl(
    str(value.canonicalUrl),
    str(value.href),
    str(value.permalink)
  );
}

type ListEntriesCursorMode =
  | { phase: "initial" }
  | { phase: "page"; colIdx: number; atproto?: string };

/**
 * Cursor encodes `collectionIndex` (see {@link LIST_COLLECTIONS_ORDER}) plus optional
 * ATProto `listRecords` cursor. Legacy `d:` / `e:` prefixes map to older two-phase pagination.
 */
function decodeListCursor(cursor: string | undefined): ListEntriesCursorMode {
  if (cursor === undefined || cursor === "") return { phase: "initial" };

  const digitPrefix = cursor.match(/^(\d+):(.*)$/);
  if (digitPrefix) {
    const colIdx = parseInt(digitPrefix[1], 10);
    const raw = digitPrefix[2];
    return {
      phase: "page",
      colIdx,
      atproto: raw ? decodeURIComponent(raw) : undefined,
    };
  }

  if (cursor.startsWith(LIST_CURSOR_DOC)) {
    const raw = cursor.slice(LIST_CURSOR_DOC.length);
    return {
      phase: "page",
      colIdx: 0,
      atproto: raw ? decodeURIComponent(raw) : undefined,
    };
  }
  if (cursor.startsWith(LIST_CURSOR_ENT)) {
    const raw = cursor.slice(LIST_CURSOR_ENT.length);
    return {
      phase: "page",
      colIdx: 2,
      atproto: raw ? decodeURIComponent(raw) : undefined,
    };
  }
  return { phase: "page", colIdx: 0, atproto: cursor };
}

export type ListEntriesPageCursorState = ListEntriesCursorMode;

/** Decodes the infinite-query `listEntries` cursor (collection index + optional PDS cursor token). */
export function decodeListEntriesPageCursor(
  cursor: string | undefined
): ListEntriesPageCursorState {
  return decodeListCursor(cursor);
}

/**
 * Computes the infinite-query cursor after a non-empty `listRecords` page when listing
 * across {@link LIST_COLLECTIONS_ORDER}. When the PDS returns no `cursor`, advance to the
 * next collection instead of stopping (otherwise entries in later NSIDs never load).
 */
export function computeNextListEntriesPageCursor(
  colIdx: number,
  colCount: number,
  listRecordsCursor: string | undefined
): string | undefined {
  if (listRecordsCursor) {
    return `${colIdx}:${encodeURIComponent(listRecordsCursor)}`;
  }
  if (colIdx + 1 < colCount) {
    return `${colIdx + 1}:`;
  }
  return undefined;
}

/** Most-recent first using ISO `publishedAt` (lexicographic order), then AT-URI for stability. */
export function sortEntryListItemsNewestFirst(
  entries: EntryListItem[]
): EntryListItem[] {
  return [...entries].sort((a, b) => {
    const byTime = b.publishedAt.localeCompare(a.publishedAt);
    if (byTime !== 0) return byTime;
    return a.entryId.localeCompare(b.entryId);
  });
}

async function recordsToListItems(
  records: Array<{ uri: string; value: unknown }>,
  oauthSession?: OAuthSession
): Promise<EntryListItem[]> {
  return Promise.all(
    records.map(async (record) => {
      const parsed = parseEntryValue(record.value as Record<string, unknown>);
      const thumbnails = await resolveEntryThumbnailUrls(
        record.uri,
        record.value,
        oauthSession
      );
      return {
        entryId: record.uri,
        title: parsed.title,
        summary: parsed.summary,
        publishedAt: parsed.publishedAt,
        thumbnailUrl: thumbnails.thumbnailUrl,
        thumbnailFallbackUrl: thumbnails.thumbnailFallbackUrl,
      };
    })
  );
}

export type ListEntriesOptions = {
  /**
   * Called when a non-empty page of records arrives (including while skipping empty collections).
   * `cursor` is the encoded infinite-query page cursor that would be returned for this batch.
   */
  onProgress?: (payload: {
    entries: EntryListItem[];
    cursor?: string;
  }) => void;
  signal?: AbortSignal;
  /**
   * When set, only document/entry records whose `site` field references this publication
   * AT-URI are returned (scoped publication feed).
   */
  publicationAtUri?: string;
};

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

// ── Public API ────────────────────────────────────────────────────────────────

export type DiscoverPublicationsOptions = {
  /** When aborted, probing stops between batch chunks. */
  signal?: AbortSignal;
  /**
   * Called whenever a new publication is found, with the **full list so far** in
   * **follow-graph order** (only includes DIDs that have been resolved to a publication).
   */
  onProgress?: (orderedPublications: DiscoveredPublication[]) => void;
};

/**
 * Lists every `site.standard.publication` / `com.standard.publication` record in the author's
 * repo (paginated). Used so the viewer can see **all** owned publications, not only the first.
 */
export async function discoverOwnPublications(
  authorDid: string,
  oauthSession: OAuthSession,
  options?: { signal?: AbortSignal }
): Promise<DiscoveredPublication[]> {
  const discoveredAt = new Date().toISOString();
  const seen = new Set<string>();
  const out: DiscoveredPublication[] = [];

  for (const collection of DISCOVERY_PUBLICATION_COLLECTIONS) {
    let cursor: string | undefined;
    do {
      if (options?.signal?.aborted) return out;
      const { records, cursor: next } = await listRecordsOnAuthorRepo(
        authorDid,
        collection,
        {
          limit: OWN_PUBLICATIONS_PAGE_LIMIT,
          cursor,
          reverse: false,
          signal: options?.signal,
        },
        oauthSession
      );
      for (const row of records) {
        if (seen.has(row.uri)) continue;
        seen.add(row.uri);
        const val = row.value as Record<string, unknown>;
        const label = authorDid;
        out.push({
          publicationId: row.uri,
          authorDid,
          authorHandle: authorDid,
          title: publicationTitleFromRecord(collection, val, label),
          discoveredAt,
        });
      }
      cursor = next;
    } while (cursor);
  }
  return out;
}

/**
 * Discovers followed authors with standard.site-related records.
 *
 * Follow subjects come from:
 * - **`app.bsky.graph.follow`** on the viewer's repo (OAuth / PDS — canonical graph).
 * - **`app.bsky.graph.getFollows`** on the Bluesky relay (additional mirrored edges).
 *
 * Each followed repo is probed via **that author's PDS** (PLC); optional OAuth retry on 400/401/403.
 */
export async function discoverPublications(
  userDid: string,
  session: OAuthSession,
  options?: DiscoverPublicationsOptions
): Promise<DiscoveredPublication[]> {
  const { signal, onProgress } = options ?? {};

  const relayAgent = new Agent(BSKY_APPVIEW_PUBLIC);

  const subjectDids = new Set<string>();
  // Include the viewer's repo so authored publications surface (follow graph excludes self-follows).
  subjectDids.add(userDid);

  try {
    let cursor: string | undefined;
    do {
      const { records, cursor: next } = await listRecordsOnAuthorRepo(
        userDid,
        GRAPH_FOLLOW_COLLECTION,
        { limit: FOLLOW_PAGE_LIMIT, cursor, reverse: false },
        session
      );
      for (const record of records) {
        const val = record.value as { subject?: string };
        if (typeof val.subject === "string") subjectDids.add(val.subject);
        if (subjectDids.size >= MAX_FOLLOWS) break;
      }
      cursor = next;
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

  if (signal?.aborted) {
    return [];
  }

  /** Stable follow order while probes finish out-of-order (parallel batches). */
  const foundByDid = new Map<string, DiscoveredPublication>();
  let viewerPublications: DiscoveredPublication[] = [];

  const discoveredAt = new Date().toISOString();

  async function probeFollow(
    follow: FollowProfile
  ): Promise<DiscoveredPublication | null> {
    const sidebarLabel =
      follow.displayName?.trim() || follow.handle || follow.did;

    for (const collection of DISCOVERY_PUBLICATION_COLLECTIONS) {
      const { records: rows } = await listRecordsOnAuthorRepo(
        follow.did,
        collection,
        { limit: 1, reverse: false },
        session
      );
      if (rows.length === 0) continue;

      const firstVal = rows[0]!.value as Record<string, unknown>;
      const title = publicationTitleFromRecord(
        collection,
        firstVal,
        sidebarLabel
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

    for (const collection of DISCOVERY_CONTENT_COLLECTIONS) {
      const { records: rows } = await listRecordsOnAuthorRepo(
        follow.did,
        collection,
        { limit: 1, reverse: false },
        session
      );
      if (rows.length === 0) continue;

      return {
        publicationId: follow.did,
        authorDid: follow.did,
        authorHandle: follow.handle,
        title: sidebarLabel,
        avatarUrl: follow.avatar,
        discoveredAt,
      };
    }

    return null;
  }

  async function hydrateViewerPublications(): Promise<void> {
    const viewer = follows.find((f) => f.did === userDid);
    if (!viewer) {
      viewerPublications = [];
      return;
    }
    const listed = await discoverOwnPublications(userDid, session, {
      signal,
    });
    if (listed.length > 0) {
      viewerPublications = listed.map((p) => ({
        ...p,
        authorHandle: viewer.handle,
        avatarUrl: viewer.avatar,
      }));
      return;
    }
    const fallback = await probeFollow(viewer);
    viewerPublications = fallback ? [fallback] : [];
  }

  function snapshotOrdered(): DiscoveredPublication[] {
    const list: DiscoveredPublication[] = [];
    for (const f of follows) {
      if (f.did === userDid) {
        for (const p of viewerPublications) list.push(p);
      } else {
        const pub = foundByDid.get(f.did);
        if (pub) list.push(pub);
      }
    }
    return list;
  }

  onProgress?.([]);

  await hydrateViewerPublications();
  if (signal?.aborted) {
    return snapshotOrdered();
  }
  onProgress?.(snapshotOrdered());

  for (let i = 0; i < follows.length; i += DISCOVERY_BATCH_SIZE) {
    if (signal?.aborted) break;

    const batch = follows.slice(i, i + DISCOVERY_BATCH_SIZE);
    await Promise.allSettled(
      batch.map(async (follow) => {
        if (follow.did === userDid) return;
        const pub = await probeFollow(follow);
        if (pub) {
          foundByDid.set(follow.did, pub);
          onProgress?.(snapshotOrdered());
        }
      })
    );
  }

  return snapshotOrdered();
}

function decodePublicationListCursor(cursor: string | undefined): {
  colIdx: number;
  atproto?: string;
  matchSkip: number;
} {
  if (cursor === undefined || cursor === "") {
    return { colIdx: 0, matchSkip: 0 };
  }
  if (!cursor.startsWith("p|")) {
    return { colIdx: 0, matchSkip: 0 };
  }
  const parts = cursor.slice(2).split("|");
  const colIdx = Math.max(0, parseInt(parts[0] ?? "0", 10) || 0);
  const rawAt = parts[1];
  const atproto =
    rawAt !== undefined && rawAt !== ""
      ? decodeURIComponent(rawAt)
      : undefined;
  const matchSkip = Math.max(0, parseInt(parts[2] ?? "0", 10) || 0);
  return { colIdx, atproto: atproto || undefined, matchSkip };
}

export type PublicationScopeListCursor = {
  colIdx: number;
  atproto?: string;
  matchSkip: number;
};

/** Decodes publication-scoped `p|…` cursors ({@link listEntries} with `publicationAtUri`). */
export function decodePublicationScopeListCursor(
  cursor: string | undefined
): PublicationScopeListCursor {
  return decodePublicationListCursor(cursor);
}

function encodePublicationListCursor(
  colIdx: number,
  atproto: string | undefined,
  matchSkip: number
): string {
  return `p|${colIdx}|${encodeURIComponent(atproto ?? "")}|${matchSkip}`;
}

/** Stable key for comparing a publication AT-URI to document `site` / strong-ref URIs. */
function canonicalPublicationAtUriKey(uri: string): string | null {
  const n = normalizeAtRepoParam(uri);
  const p = parseAtUri(n);
  if (!p) return null;
  const did =
    p.did.toLowerCase().startsWith("did:plc:") ? p.did.toLowerCase() : p.did;
  return `at://${did}/${p.collection}/${p.rkey}`;
}

/**
 * Acceptable canonical AT-URI keys when scoping entries to a publication record.
 * Includes `site.standard.publication` ↔ `com.standard.publication` mirror pairs (same DID + rkey).
 */
function publicationFilterEquivalenceKeys(publicationAtUri: string): Set<string> {
  const keys = new Set<string>();
  const primary = canonicalPublicationAtUriKey(publicationAtUri);
  if (primary) keys.add(primary);

  const p = parseAtUri(normalizeAtRepoParam(publicationAtUri));
  if (!p || !PUBLICATION_RECORD_COLLECTIONS.has(p.collection)) return keys;

  const didNorm = p.did.toLowerCase().startsWith("did:plc:")
    ? p.did.toLowerCase()
    : p.did;
  if (p.collection === "site.standard.publication") {
    keys.add(`at://${didNorm}/com.standard.publication/${p.rkey}`);
  } else if (p.collection === "com.standard.publication") {
    keys.add(`at://${didNorm}/site.standard.publication/${p.rkey}`);
  }
  return keys;
}

export function entryRecordMatchesPublication(
  recordValue: unknown,
  publicationAtUri: string
): boolean {
  if (!recordValue || typeof recordValue !== "object") return false;
  const wantKeys = publicationFilterEquivalenceKeys(publicationAtUri);
  if (wantKeys.size === 0) return false;
  const site = (recordValue as Record<string, unknown>).site;
  if (typeof site === "string") {
    const got = canonicalPublicationAtUriKey(site);
    return got !== null && wantKeys.has(got);
  }
  const ref = parseStrongRef(site);
  if (!ref?.uri) return false;
  const got = canonicalPublicationAtUriKey(ref.uri);
  return got !== null && wantKeys.has(got);
}

async function listEntriesForPublicationScope(
  authorDid: string,
  publicationAtUri: string,
  cursor: string | undefined,
  limit: number,
  oauthSession: OAuthSession | undefined,
  options: Pick<ListEntriesOptions, "onProgress" | "signal">
): Promise<{ entries: EntryListItem[]; cursor?: string }> {
  const { onProgress, signal } = options;
  const colCount = LIST_COLLECTIONS_ORDER.length;
  const initial = decodePublicationListCursor(cursor);
  let col = Math.min(Math.max(initial.colIdx, 0), colCount - 1);
  let listCursor = initial.atproto;
  let matchSkip = initial.matchSkip;
  const out: EntryListItem[] = [];

  while (out.length < limit && col < colCount) {
    if (signal?.aborted) {
      return { entries: [], cursor: undefined };
    }

    const res = await listRecordsOnAuthorRepo(
      authorDid,
      LIST_COLLECTIONS_ORDER[col],
      {
        limit: OWN_PUBLICATIONS_PAGE_LIMIT,
        cursor: listCursor,
        reverse: true,
        signal,
      },
      oauthSession
    );

    const filteredItems = await recordsToListItems(
      res.records.filter((r) =>
        entryRecordMatchesPublication(r.value, publicationAtUri)
      ),
      oauthSession
    );
    const slice = filteredItems.slice(matchSkip);
    const need = limit - out.length;
    const chunk = slice.slice(0, need);
    out.push(...chunk);

    if (out.length >= limit) {
      let nextCursor: string | undefined;
      if (chunk.length < slice.length) {
        nextCursor = encodePublicationListCursor(
          col,
          listCursor,
          matchSkip + chunk.length
        );
      } else if (res.cursor) {
        nextCursor = encodePublicationListCursor(col, res.cursor, 0);
      } else if (col + 1 < colCount) {
        nextCursor = encodePublicationListCursor(col + 1, undefined, 0);
      }
      const payload = { entries: out, cursor: nextCursor };
      onProgress?.(payload);
      return payload;
    }

    if (res.cursor) {
      listCursor = res.cursor;
      matchSkip = 0;
      continue;
    }

    col += 1;
    listCursor = undefined;
    matchSkip = 0;
  }

  const payload = { entries: out, cursor: undefined };
  onProgress?.(payload);
  return payload;
}

/**
 * Lists entries for a given author handle or DID, walking {@link LIST_COLLECTIONS_ORDER} so every
 * document/entry NSID is paginated (cursors advance across collections when a slice has no PDS cursor).
 * The UI should merge pages and sort by record time — {@link sortEntryListItemsNewestFirst} uses
 * `publishedAt` from the lexicon (`publishedAt` → `createdAt` → `indexedAt` in {@link parseEntryValue}).
 * Legacy `d:` / `e:` cursors from older clients are still accepted.
 *
 * With `options.publicationAtUri`, only records whose **`site`** matches that publication AT-URI
 * are returned, using `p|`-prefixed cursors.
 */
export async function listEntries(
  authorDid: string,
  cursor?: string,
  limit = 50,
  oauthSession?: OAuthSession,
  options?: ListEntriesOptions
): Promise<{ entries: EntryListItem[]; cursor?: string }> {
  const { onProgress, signal, publicationAtUri } = options ?? {};

  if (publicationAtUri) {
    return listEntriesForPublicationScope(
      authorDid,
      publicationAtUri,
      cursor,
      limit,
      oauthSession,
      { onProgress, signal }
    );
  }

  const mode = decodeListCursor(cursor);
  const colCount = LIST_COLLECTIONS_ORDER.length;

  let startIdx = 0;
  let startAtproto: string | undefined;

  if (mode.phase === "page") {
    startIdx = mode.colIdx;
    startAtproto = mode.atproto;
    if (startIdx < 0 || startIdx >= colCount) {
      return { entries: [], cursor: undefined };
    }
  }

  let i = startIdx;
  while (i < colCount) {
    if (signal?.aborted) {
      return { entries: [], cursor: undefined };
    }

    let pageCursor: string | undefined = i === startIdx ? startAtproto : undefined;

    for (;;) {
      const res = await listRecordsOnAuthorRepo(
        authorDid,
        LIST_COLLECTIONS_ORDER[i],
        { limit, cursor: pageCursor, reverse: true, signal },
        oauthSession
      );

      if (res.records.length > 0) {
        const entries = await recordsToListItems(res.records, oauthSession);
        const nextCursor = computeNextListEntriesPageCursor(
          i,
          colCount,
          res.cursor
        );
        onProgress?.({ entries, cursor: nextCursor });
        return { entries, cursor: nextCursor };
      }

      if (res.cursor) {
        pageCursor = res.cursor;
        continue;
      }

      break;
    }

    i += 1;
    startAtproto = undefined;
  }

  return { entries: [], cursor: undefined };
}

/**
 * Fetches the full content for a single entry by its AT-URI.
 */
export async function getEntry(
  entryId: string,
  oauthSession?: OAuthSession
): Promise<EntryDetail | null> {
  const parsed = parseAtUri(entryId);
  if (!parsed) return null;

  const normalizedEntryId = `at://${parsed.did}/${parsed.collection}/${parsed.rkey}`;

  const raw = (await getRecordOnAuthorRepo(
    parsed.did,
    parsed.collection,
    parsed.rkey,
    oauthSession
  )) as Record<string, unknown> | null;
  if (!raw) return null;

  const fields = parseEntryValue(raw);

  const embedFromFields = extractHttpsUrl(fields.originalUrl);
  const embedResolved =
    embedFromFields ?? (await resolveEmbedUrl(raw, oauthSession));
  const embedUrl = embedResolved
    ? normalizeHttpUrlToHttps(embedResolved)
    : undefined;

  const bskyRef = parseStrongRef(raw.bskyPostRef);

  return {
    entryId: normalizedEntryId,
    title: fields.title,
    publishedAt: fields.publishedAt,
    contentHtml: fields.contentHtml,
    originalUrl: fields.originalUrl
      ? normalizeHttpUrlToHttps(fields.originalUrl)
      : undefined,
    embedUrl,
    bskyPostUri: bskyRef?.uri,
    bskyPostCid: bskyRef?.cid,
  };
}
