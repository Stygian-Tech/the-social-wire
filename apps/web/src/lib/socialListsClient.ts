import { Agent, AppBskyGraphList, type ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";

const newlyCreatedLists = new Map<string, number>();
const LIST_INDEXING_BACKOFF = [500, 1_000, 2_000, 4_000, 8_000];
function listIndexKey(session: OAuthSession, uri: string) { return `${session.did}:${uri}`; }
function isListNotIndexed(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const failure = error as { error?: unknown; message?: unknown };
  return failure.error === "InvalidRequest" && typeof failure.message === "string" && /^list not found[.!]?$/i.test(failure.message.trim());
}
function waitForIndexing(milliseconds: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) { reject(signal.reason ?? new DOMException("Aborted", "AbortError")); return; }
    const abort = () => { clearTimeout(timer); reject(signal?.reason ?? new DOMException("Aborted", "AbortError")); };
    const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, milliseconds);
    signal?.addEventListener("abort", abort, { once: true });
  });
}

export function ownedSocialRecord(session: OAuthSession, uri: string, collection: string) {
  const match = /^at:\/\/([^/]+)\/([^/]+)\/([^/?#]+)$/.exec(uri);
  if (!match || match[1] !== session.did || match[2] !== collection) throw new Error("You can only edit your own lists and members.");
  return { repo: session.did, collection, rkey: match[3]! };
}
export async function getSocialLists(session: OAuthSession, cursor?: string, signal?: AbortSignal, moderation?: ModerationOpts) {
  const agent = createAuthenticatedAppViewAgent(session);
  agent.configureLabelers(moderation?.prefs.labelers.map(item => item.did) ?? []);
  return (await agent.app.bsky.graph.getLists({ actor: session.did, cursor, limit: 30 }, { signal })).data;
}
export async function getSocialList(session: OAuthSession, uri: string, cursor?: string, signal?: AbortSignal, moderation?: ModerationOpts) {
  const agent = createAuthenticatedAppViewAgent(session);
  agent.configureLabelers(moderation?.prefs.labelers.map(item => item.did) ?? []);
  const key = listIndexKey(session, uri);
  const indexingExpires = newlyCreatedLists.get(key);
  const retryIndexing = !cursor && indexingExpires !== undefined && indexingExpires > Date.now();
  if (indexingExpires !== undefined && !retryIndexing) newlyCreatedLists.delete(key);
  for (let attempt = 0; ; attempt++) {
    try {
      const { data } = await agent.app.bsky.graph.getList({ list: uri, cursor, limit: 50 }, { signal });
      newlyCreatedLists.delete(key);
      return data;
    } catch (error) {
      if (!retryIndexing || !isListNotIndexed(error) || attempt >= LIST_INDEXING_BACKOFF.length || signal?.aborted) throw error;
      await waitForIndexing(LIST_INDEXING_BACKOFF[attempt]!, signal);
    }
  }
}
export async function saveSocialList(session: OAuthSession, name: string, description: string, uri?: string) {
  name = name.trim(); description = description.trim();
  if (!name || Array.from(name).length > 64 || Array.from(description).length > 300) throw new Error("Use a name up to 64 characters and a description up to 300 characters.");
  const agent = new Agent(session);
  if (!uri) {
    const created = (await agent.com.atproto.repo.createRecord({ repo: session.did, collection: "app.bsky.graph.list", record: { $type: "app.bsky.graph.list", name, description, purpose: "app.bsky.graph.defs#curatelist", createdAt: new Date().toISOString() } })).data.uri;
    const now = Date.now();
    for (const [key, expires] of newlyCreatedLists) if (expires <= now) newlyCreatedLists.delete(key);
    newlyCreatedLists.set(listIndexKey(session, created), now + 60_000);
    return created;
  }
  const params = ownedSocialRecord(session, uri, "app.bsky.graph.list");
  const { data } = await agent.com.atproto.repo.getRecord(params);
  const record = AppBskyGraphList.validateRecord(data.value);
  if (!record.success) throw new Error("This list record cannot be safely edited.");
  const updated = { ...record.value, name, description };
  delete updated.descriptionFacets;
  await agent.com.atproto.repo.putRecord({ ...params, record: updated, swapRecord: data.cid });
  return uri;
}
export async function deleteSocialList(session: OAuthSession, uri: string) {
  const params = ownedSocialRecord(session, uri, "app.bsky.graph.list");
  const agent = new Agent(session);
  // Enumerate canonical repo items rather than a lagging AppView; delete only this list's members.
  let cursor: string | undefined;
  const seen = new Set<string>();
  do {
    const { data } = await agent.com.atproto.repo.listRecords({ repo: session.did, collection: "app.bsky.graph.listitem", limit: 100, cursor });
    for (const row of data.records) if (row.value && typeof row.value === "object" && "list" in row.value && row.value.list === uri) await agent.com.atproto.repo.deleteRecord({ ...ownedSocialRecord(session, row.uri, "app.bsky.graph.listitem"), swapRecord: row.cid });
    if (!data.cursor) break;
    if (seen.has(data.cursor)) throw new Error("List cleanup pagination stalled. Please retry.");
    seen.add(data.cursor); cursor = data.cursor;
  } while (cursor);
  await agent.com.atproto.repo.deleteRecord(params);
}
export async function addSocialListMember(session: OAuthSession, list: string, actor: string) {
  ownedSocialRecord(session, list, "app.bsky.graph.list");
  const profile = (await createAuthenticatedAppViewAgent(session).app.bsky.actor.getProfile({ actor: actor.trim().replace(/^@/, "") })).data;
  const agent = new Agent(session);
  let cursor: string | undefined;
  const seen = new Set<string>();
  do {
    const { data } = await agent.com.atproto.repo.listRecords({ repo: session.did, collection: "app.bsky.graph.listitem", limit: 100, cursor });
    if (data.records.some(row => row.value && typeof row.value === "object" && "list" in row.value && "subject" in row.value && row.value.list === list && row.value.subject === profile.did)) return;
    if (!data.cursor) break;
    if (seen.has(data.cursor)) throw new Error("Member pagination stalled. Please retry.");
    seen.add(data.cursor); cursor = data.cursor;
  } while (cursor);
  await agent.com.atproto.repo.createRecord({ repo: session.did, collection: "app.bsky.graph.listitem", record: { $type: "app.bsky.graph.listitem", list, subject: profile.did, createdAt: new Date().toISOString() } });
}
export async function removeSocialListMember(session: OAuthSession, uri: string) {
  await new Agent(session).com.atproto.repo.deleteRecord(ownedSocialRecord(session, uri, "app.bsky.graph.listitem"));
}
