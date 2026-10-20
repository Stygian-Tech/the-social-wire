import { buildDocumentRecord, buildNativeDocumentWrapper } from "@stygian/anypub-kit/records";
import { AppBskyRichtextFacet, ComAtprotoRepoStrongRef, RichText } from "@atproto/api";
import { TID } from "@atproto/common-web";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";
import { articleDraftRecordKey, articlePublicationHost, listArticlePublications } from "@/lib/articles/articlePublishingClient";
import type { ArticleRecord } from "@/lib/articles/articlePublishingTypes";
import { appendLiveArticleContent, livePostText } from "./livePostContent";
import type { CreateLiveEventInput, LiveEvent, LiveReference } from "./livePostTypes";
export type { LiveEventInput, CreateLiveEventInput, LiveDestination, LiveEvent, LiveUpdate, LiveReference } from "./livePostTypes";
export const LIVE_EVENT_COLLECTION = "app.thesocialwire.liveEvent";
const DOCUMENT = "site.standard.document", POST = "app.bsky.feed.post";
type Write = { $type: "com.atproto.repo.applyWrites#create" | "com.atproto.repo.applyWrites#update"; collection: string; rkey: string; value: ArticleRecord };
export type LiveUpdateOperation = { operationId: string; createdAt: string; signal?: AbortSignal; assertCurrentAccount?: () => void };
function recordKey(uri: string, did: string, collection: string): string {
  const prefix = `at://${did}/${collection}/`, result = uri.slice(prefix.length);
  if (!uri.startsWith(prefix) || !/^[a-zA-Z0-9._~:-]+$/.test(result)) throw new Error("This live event does not belong to the signed-in account.");
  return result;
}
function eventRecord(event: LiveEvent): ArticleRecord { const { uri: _uri, cid: _cid, ...record } = event; void _uri; void _cid; return record; }
const utf8Length = (value: string) => new TextEncoder().encode(value).length;
function validTime(value: unknown): value is string { return typeof value === "string" && /^\d{4}-\d{2}-\d{2}T/.test(value) && Number.isFinite(Date.parse(value)); }
function validateEventSchedule(value: { sourceEvent?: LiveReference; startsAt?: string; endsAt?: string }) {
  if ((value.startsAt !== undefined && !validTime(value.startsAt)) || (value.endsAt !== undefined && !validTime(value.endsAt)) || (value.startsAt && value.endsAt && Date.parse(value.endsAt) < Date.parse(value.startsAt))) throw new Error("Invalid live event schedule.");
  if (value.sourceEvent && (!ComAtprotoRepoStrongRef.validateMain(value.sourceEvent).success || !/^at:\/\/did:[^/?#]+\/community\.lexicon\.calendar\.event\/[^/?#]+$/.test(value.sourceEvent.uri))) throw new Error("Invalid source calendar event.");
}
function parseEvent(value: unknown, uri: string, cid: string, did: string): LiveEvent {
  recordKey(uri, did, LIVE_EVENT_COLLECTION);
  const r = value as Partial<LiveEvent>;
  if (!r || r.$type !== LIVE_EVENT_COLLECTION || typeof r.title !== "string" || !r.title.trim() || utf8Length(r.title) > 500 || !["blog", "bluesky", "both"].includes(r.destination ?? "") || !Array.isArray(r.tags) || r.tags.length > 20 || !r.tags.every(t => typeof t === "string" && !!t.trim() && utf8Length(t) <= 128) || !Array.isArray(r.entries) || r.entries.length > 500 || !validTime(r.createdAt) || !validTime(r.updatedAt)) throw new Error("Invalid live event record.");
  validateEventSchedule(r);
  const ids = new Set<string>();
  for (const entry of r.entries) {
    if (!entry.id || ids.has(entry.id) || !validTime(entry.createdAt) || typeof entry.text !== "string" || !entry.text.trim() || utf8Length(entry.text) > 30_000) throw new Error("Invalid live event update.");
    ids.add(entry.id);
    for (const ref of [entry.postRef, entry.articleRef]) if (ref && !ComAtprotoRepoStrongRef.validateMain(ref).success) throw new Error("Invalid live update reference.");
    if (entry.postRef) recordKey(entry.postRef.uri, did, POST);
    if (entry.articleRef) recordKey(entry.articleRef.uri, did, DOCUMENT);
  }
  if (r.publicationUri) recordKey(r.publicationUri, did, "site.standard.publication");
  for (const ref of [r.articleRef, r.threadRoot, r.threadLast]) if (ref && !ComAtprotoRepoStrongRef.validateMain(ref).success) throw new Error("Invalid live event reference.");
  if (r.articleRef) recordKey(r.articleRef.uri, did, DOCUMENT);
  for (const ref of [r.threadRoot, r.threadLast]) if (ref) recordKey(ref.uri, did, POST);
  const posts = r.entries.flatMap(entry => entry.postRef ? [entry.postRef] : []);
  const articles = r.entries.flatMap(entry => entry.articleRef ? [entry.articleRef] : []);
  const same = (a: LiveReference | undefined, b: LiveReference | undefined) => a?.uri === b?.uri && a?.cid === b?.cid;
  if ((r.destination !== "bluesky" && !r.publicationUri) || (r.destination === "bluesky" && (r.publicationUri || articles.length)) || (r.destination === "blog" && posts.length)
    || (r.destination !== "blog" && posts.length !== r.entries.length) || (r.destination !== "bluesky" && articles.length !== r.entries.length)
    || !same(r.threadRoot, posts[0]) || !same(r.threadLast, posts.at(-1)) || !same(r.articleRef, articles.at(-1))
    || articles.some(ref => ref.uri !== articles[0].uri)) throw new Error("Inconsistent live event destination references.");
  return { ...r, uri, cid } as LiveEvent;
}
export async function getEvent(session: OAuthSession, uri: string, signal?: AbortSignal): Promise<LiveEvent> {
  const { data } = await createOAuthAgent(session).com.atproto.repo.getRecord({ repo: session.did, collection: LIVE_EVENT_COLLECTION, rkey: recordKey(uri, session.did, LIVE_EVENT_COLLECTION) }, { signal });
  if (data.uri !== uri || !data.cid) throw new Error("The PDS returned a different live event.");
  return parseEvent(data.value, data.uri, data.cid, session.did);
}
export async function listEvents(session: OAuthSession, signal?: AbortSignal): Promise<LiveEvent[]> {
  const agent = createOAuthAgent(session), events: LiveEvent[] = [], seen = new Set<string>(); let cursor: string | undefined;
  do {
    signal?.throwIfAborted();
    const { data } = await agent.com.atproto.repo.listRecords({ repo: session.did, collection: LIVE_EVENT_COLLECTION, cursor, limit: 100 }, { signal });
    events.push(...data.records.map(r => parseEvent(r.value, r.uri, r.cid, session.did)));
    cursor = data.cursor; if (cursor && seen.has(cursor)) throw new Error("The PDS repeated a live event cursor."); if (cursor) seen.add(cursor);
  } while (cursor);
  return events.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
}
export async function createEvent(session: OAuthSession, input: CreateLiveEventInput, operation?: LiveUpdateOperation): Promise<LiveEvent> {
  validateEventSchedule(input);
  const signal = operation?.signal;
  if (operation && (!/^[a-zA-Z0-9._~-]{1,100}$/.test(operation.operationId) || !validTime(operation.createdAt))) throw new Error("Invalid live event operation.");
  operation?.assertCurrentAccount?.();
  if (!input.title.trim() || utf8Length(input.title) > 500 || !["blog", "bluesky", "both"].includes(input.destination)) throw new Error("Choose a title and destination for the live event.");
  const tags = [...new Set(input.tags.map(t => t.trim().replace(/^#/, "")).filter(Boolean))];
  if (tags.length > 20 || tags.some(t => utf8Length(t) > 128 || /[\r\n]/.test(t))) throw new Error("Use at most 20 tags of 128 characters each.");
  if (input.destination !== "bluesky" && !(await listArticlePublications(session, signal)).some(p => p.uri === input.publicationUri)) throw new Error("Select one of your publications.");
  const rkey = operation ? await articleDraftRecordKey(operation.operationId, operation.createdAt) : TID.nextStr(), now = operation?.createdAt ?? new Date().toISOString();
  const event: LiveEvent = { $type: LIVE_EVENT_COLLECTION, uri: `at://${session.did}/${LIVE_EVENT_COLLECTION}/${rkey}`, cid: "", title: input.title.trim(), tags, destination: input.destination, ...(input.destination !== "bluesky" ? { publicationUri: input.publicationUri } : {}), ...(input.sourceEvent ? { sourceEvent: input.sourceEvent } : {}), ...(input.startsAt ? { startsAt: input.startsAt } : {}), ...(input.endsAt ? { endsAt: input.endsAt } : {}), entries: [], createdAt: now, updatedAt: now };
  if (operation) {
    operation.assertCurrentAccount?.();
    try { const existing = await getEvent(session, event.uri, signal); if (existing.title !== event.title || existing.destination !== event.destination || existing.publicationUri !== event.publicationUri || JSON.stringify(existing.tags) !== JSON.stringify(event.tags) || JSON.stringify(existing.sourceEvent) !== JSON.stringify(event.sourceEvent) || existing.startsAt !== event.startsAt || existing.endsAt !== event.endsAt) throw new Error("This event identifier was already used for different settings."); return existing; } catch (error) { if (!(error && typeof error === "object" && "error" in error && error.error === "RecordNotFound")) throw error; }
  }
  return commitEvent(session, event, [{ $type: "com.atproto.repo.applyWrites#create", collection: LIVE_EVENT_COLLECTION, rkey, value: eventRecord(event) }], undefined, signal, operation?.assertCurrentAccount);
}
async function reference(did: string, collection: string, rkey: string, value: ArticleRecord): Promise<LiveReference> {
  return { uri: `at://${did}/${collection}/${rkey}`, cid: (await cidForLex(lexParse(JSON.stringify(value), { strict: true }))).toString() };
}
async function commitEvent(session: OAuthSession, event: LiveEvent, writes: Write[], swapCommit?: string, signal?: AbortSignal, assertCurrentAccount?: () => void): Promise<LiveEvent> {
  if (new TextEncoder().encode(JSON.stringify(writes.at(-1)!.value)).length > 900_000) throw new Error("The live event has reached its safe record size limit.");
  const expected = await reference(session.did, LIVE_EVENT_COLLECTION, recordKey(event.uri, session.did, LIVE_EVENT_COLLECTION), writes.at(-1)!.value);
  assertCurrentAccount?.(); signal?.throwIfAborted();
  try {
    await createOAuthAgent(session).com.atproto.repo.applyWrites({ repo: session.did, writes, ...(swapCommit ? { swapCommit } : {}) }, { signal });
  } catch (error) {
    // Exact CID readback resolves a dropped response; never blindly repeat a write.
    try { const actual = await getEvent(session, event.uri); if (actual.cid === expected.cid) return actual; } catch { /* Preserve the original mutation error. */ }
    throw error;
  }
  return { ...event, cid: expected.cid };
}
export async function publishLiveUpdate(session: OAuthSession, event: LiveEvent, text: string, operation: LiveUpdateOperation): Promise<LiveEvent> {
  const rkey = recordKey(event.uri, session.did, LIVE_EVENT_COLLECTION), signal = operation.signal;
  if (!text.trim() || new TextEncoder().encode(text).length > 30_000 || !/^[a-zA-Z0-9._~-]{1,100}$/.test(operation.operationId) || !validTime(operation.createdAt)) throw new Error("Write a valid live update and timestamp.");
  operation.assertCurrentAccount?.(); signal?.throwIfAborted();
  const agent = createOAuthAgent(session), commit = await agent.com.atproto.sync.getLatestCommit({ did: session.did }, { signal });
  const current = await getEvent(session, event.uri, signal);
  const already = current.entries.find(e => e.id === operation.operationId);
  if (already) { if (already.text !== text.trim()) throw new Error("This update identifier was already used for different text."); return current; }
  if (current.cid !== event.cid) throw new Error("This event changed elsewhere. Refresh before publishing.");
  if (current.entries.length >= 500) throw new Error("This live event has reached its 500-update limit.");
  const next = { ...current, updatedAt: operation.createdAt }, entry = { id: operation.operationId, createdAt: operation.createdAt, text: text.trim() } as LiveEvent["entries"][number];
  const writes: Write[] = [];
  // Each operation uses one stable identity across post/article/event retries.
  const updateKey = await articleDraftRecordKey(operation.operationId, operation.createdAt);
  if (current.destination !== "bluesky") {
    const publication = (await listArticlePublications(session, signal)).find(p => p.uri === current.publicationUri);
    if (!publication) throw new Error("The event publication is unavailable.");
    const host = articlePublicationHost(publication.record), docKey = current.articleRef ? recordKey(current.articleRef.uri, session.did, DOCUMENT) : rkey;
    let previous: ArticleRecord = {};
    if (current.articleRef) { const { data } = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: DOCUMENT, rkey: docKey }, { signal }); if (data.cid !== current.articleRef.cid) throw new Error("The article changed outside this event. Refresh and reconcile it before publishing."); previous = data.value as ArticleRecord; if (previous.site !== current.publicationUri) throw new Error("The article publication changed."); }
    const path = previous.path ?? (host === "offprint" ? `/a/${docKey}-live` : `/live-${docKey}`);
    const record = buildDocumentRecord({ site: publication.uri, title: current.title, path: path as string, publishedAt: (previous.publishedAt as string | undefined) ?? operation.createdAt, updatedAt: operation.createdAt, tags: current.tags, content: appendLiveArticleContent(host, previous.content as ArticleRecord | undefined, operation.createdAt, text.trim()), textContent: [previous.textContent, operation.createdAt, text.trim()].filter(Boolean).join("\n\n"), ...(host === "pckt" && !previous.langs ? { langs: ["en"] } : {}) }, previous);
    if (new TextEncoder().encode(JSON.stringify(record)).length > 900_000) throw new Error("The live article has reached its safe record size limit.");
    entry.articleRef = await reference(session.did, DOCUMENT, docKey, record); next.articleRef = entry.articleRef; next.articleUrl = `${publication.url}${path}`;
    writes.push({ $type: `com.atproto.repo.applyWrites#${current.articleRef ? "update" : "create"}`, collection: DOCUMENT, rkey: docKey, value: record });
    if (host === "offprint" || host === "pckt") {
      const collection = host === "offprint" ? "app.offprint.document.article" : "blog.pckt.document";
      let wrapper: ArticleRecord = {};
      if (current.articleRef) { const { data } = await agent.com.atproto.repo.getRecord({ repo: session.did, collection, rkey: docKey }, { signal }); wrapper = data.value as ArticleRecord; const ref = wrapper.document as LiveReference; if (ref?.uri !== current.articleRef.uri || ref.cid !== current.articleRef.cid) throw new Error("The native article wrapper changed."); }
      if (host === "pckt" && !current.articleRef) { const pk = recordKey(publication.uri, session.did, "site.standard.publication"); const { data } = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: "blog.pckt.publication", rkey: pk }, { signal }); const ref = (data.value as ArticleRecord).publication as LiveReference; if (ref?.uri !== publication.uri || ref.cid !== publication.cid) throw new Error("The native publication is unavailable."); wrapper.site = data.uri; }
      writes.push({ $type: `com.atproto.repo.applyWrites#${current.articleRef ? "update" : "create"}`, collection, rkey: docKey, value: buildNativeDocumentWrapper(host, entry.articleRef, wrapper.site as string | undefined, wrapper) });
    }
  }
  if (current.destination !== "blog") {
    const rich = new RichText({ text: livePostText(`${current.title}\n\n${text}`, current.tags) });
    if (rich.graphemeLength > 300 || new TextEncoder().encode(rich.text).length > 3000) throw new Error("Bluesky updates including event tags must fit 300 characters and 3,000 bytes.");
    await rich.detectFacets(createAuthenticatedAppViewAgent(session));
    rich.facets = rich.facets?.map(f => ({ ...f, features: f.features.filter(feature => !AppBskyRichtextFacet.isMention(feature) || feature.did.startsWith("did:")) })).filter(f => f.features.length);
    const value: ArticleRecord = { $type: POST, text: rich.text, createdAt: operation.createdAt, ...(rich.facets?.length ? { facets: rich.facets } : {}), ...(current.threadRoot && current.threadLast ? { reply: { root: current.threadRoot, parent: current.threadLast } } : {}) };
    entry.postRef = await reference(session.did, POST, updateKey, value); next.threadRoot = current.threadRoot ?? entry.postRef; next.threadLast = entry.postRef;
    writes.push({ $type: "com.atproto.repo.applyWrites#create", collection: POST, rkey: updateKey, value });
  }
  next.entries = [...current.entries, entry];
  writes.push({ $type: "com.atproto.repo.applyWrites#update", collection: LIVE_EVENT_COLLECTION, rkey, value: eventRecord(next) });
  return commitEvent(session, next, writes, commit.data.cid, signal, operation.assertCurrentAccount);
}
