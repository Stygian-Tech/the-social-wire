import { RichText } from "@atproto/api";
import { Secp256k1Keypair, bytesToMultibase } from "@atproto/crypto";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { streamplaceNodeOrigin, streamplacePublicJSON } from "./streamplaceNode";
import type { Livestream, LivestreamInput, LivestreamRecord, StreamBlob, StreamIngest, StreamKey, StreamOperation } from "./livestreamTypes";
const COLLECTION = "place.stream.livestream";
const utf8 = (text: string) => new TextEncoder().encode(text);
function ownKey(session: OAuthSession, uri: string, collection = COLLECTION): string {
  const prefix = `at://${session.did}/${collection}/`; const key = uri.slice(prefix.length);
  if (!uri.startsWith(prefix) || !/^[a-zA-Z0-9._~:-]+$/.test(key)) throw new Error("The stream does not belong to this account.");
  return key;
}
function validateInput(input: LivestreamInput) {
  if (!input.title.trim() || new RichText({ text: input.title }).graphemeLength > 140 || utf8(input.title).length > 1400) throw new Error("Livestream titles need 1–140 characters.");
  if (input.tags.length > 10 || input.tags.some(tag => !/^[a-zA-Z0-9:]+$/.test(tag) || tag.length > 64)) throw new Error("Use up to 10 alphanumeric tags; colons are allowed.");
  if (input.thumb && (input.thumb.$type !== "blob" || !/^image\//.test(input.thumb.mimeType) || input.thumb.size > 1_000_000)) throw new Error("Use an image thumbnail of at most 1 MB.");
}
export async function listLivestreams(session: OAuthSession, signal?: AbortSignal): Promise<Livestream[]> {
  const agent = createOAuthAgent(session), seen = new Set<string>(), streams: Livestream[] = []; let cursor: string | undefined;
  do {
    const { data } = await agent.com.atproto.repo.listRecords({ repo: session.did, collection: COLLECTION, cursor, limit: 100 }, { signal });
    for (const item of data.records) { ownKey(session, item.uri); const record = item.value as LivestreamRecord; if (record.$type !== COLLECTION || typeof record.title !== "string" || !Number.isFinite(Date.parse(record.createdAt))) throw new Error("The PDS returned an invalid livestream."); streams.push({ uri: item.uri, cid: item.cid, record }); }
    cursor = data.cursor; if (cursor && seen.has(cursor)) throw new Error("The PDS repeated a stream cursor."); if (cursor) seen.add(cursor);
  } while (cursor);
  return streams.sort((a, b) => Date.parse(b.record.createdAt) - Date.parse(a.record.createdAt));
}
export async function getStreamIngests(node: string, signal?: AbortSignal): Promise<StreamIngest[]> {
  const data = await streamplacePublicJSON(node, "/xrpc/place.stream.ingest.getIngestUrls", signal) as { ingests?: StreamIngest[] };
  if (!Array.isArray(data.ingests)) throw new Error("This node returned invalid ingest settings.");
  return data.ingests.map(ingest => { const url = new URL(ingest.url); if (!["rtmp", "rtmps", "whip"].includes(ingest.type) || url.username || url.password || url.protocol !== ({ rtmp: "rtmp:", rtmps: "rtmps:", whip: "https:" } as const)[ingest.type]) throw new Error("This node returned unsafe ingest settings."); return ingest; });
}
/** The secret exists only in caller memory; the PDS receives the public signing key. */
export async function generateStreamKey(session: OAuthSession, operation: StreamOperation): Promise<StreamKey> {
  operation.assertCurrentAccount?.();
  const keypair = await Secp256k1Keypair.create({ exportable: true }), privateBytes = await keypair.export();
  const secret = bytesToMultibase(new Uint8Array([...privateBytes, ...utf8(session.did)]), "base58btc");
  privateBytes.fill(0);
  const signingKey = keypair.did(), record = { $type: "place.stream.key", signingKey, createdAt: operation.createdAt, createdBy: "The Social Wire" };
  operation.assertCurrentAccount?.();
  await writeRecord(session, "place.stream.key", record, operation, undefined);
  return { secret, signingKey, uri: `at://${session.did}/place.stream.key/${operation.rkey}` };
}
async function writeRecord(session: OAuthSession, collection: string, record: Record<string, unknown>, operation: StreamOperation, existing?: Livestream): Promise<Livestream> {
  if (!/^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$/.test(operation.rkey) || !Number.isFinite(Date.parse(operation.createdAt))) throw new Error("Invalid stream operation identity.");
  const agent = createOAuthAgent(session), uri = `at://${session.did}/${collection}/${operation.rkey}`;
  const expectedCid = (await cidForLex(lexParse(JSON.stringify(record), { strict: true }))).toString();
  const commit = await agent.com.atproto.sync.getLatestCommit({ did: session.did });
  if (existing) { ownKey(session, existing.uri); const { data } = await agent.com.atproto.repo.getRecord({ repo: session.did, collection, rkey: operation.rkey }); if (data.uri === uri && data.cid === expectedCid) { operation.assertCurrentAccount?.(); return { uri, cid: expectedCid, record: record as LivestreamRecord }; } if (data.uri !== existing.uri || data.cid !== existing.cid) throw new Error("This livestream changed elsewhere. Refresh before saving."); }
  operation.assertCurrentAccount?.();
  try {
    await agent.com.atproto.repo.applyWrites({ repo: session.did, swapCommit: commit.data.cid, writes: [{ $type: `com.atproto.repo.applyWrites#${existing ? "update" : "create"}`, collection, rkey: operation.rkey, value: record }] });
  } catch (error) {
    try { const { data } = await agent.com.atproto.repo.getRecord({ repo: session.did, collection, rkey: operation.rkey }); if (data.uri === uri && data.cid === expectedCid) return { uri, cid: expectedCid, record: record as LivestreamRecord }; } catch { /* Never repeat an unconfirmed write. */ }
    throw error;
  }
  return { uri, cid: expectedCid, record: record as LivestreamRecord };
}
export async function saveLivestream(session: OAuthSession, node: string, input: LivestreamInput, operation: StreamOperation, existing?: Livestream): Promise<Livestream> {
  validateInput(input); const origin = streamplaceNodeOrigin(node);
  if (existing?.record.url && new URL(existing.record.url).origin !== origin) throw new Error("Connect This Livestream’s Original Node Before Editing.");
  if (existing?.record.endedAt) throw new Error("Ended livestreams cannot be restarted or edited.");
  const record: LivestreamRecord = { ...(existing?.record ?? {}), $type: COLLECTION, title: input.title.trim(), tags: [...new Set(input.tags)], createdAt: existing?.record.createdAt ?? operation.createdAt, url: origin, canonicalUrl: `${origin}/${session.did}` };
  if (input.thumb) record.thumb = input.thumb;
  if (!existing) {
    const streams = await listLivestreams(session);
    const uri = `at://${session.did}/${COLLECTION}/${operation.rkey}`;
    const prior = streams.find(stream => stream.uri === uri);
    if (prior) {
      const expectedCid = (await cidForLex(lexParse(JSON.stringify(record), { strict: true }))).toString();
      if (prior.cid !== expectedCid) throw new Error("This Livestream Operation Changed Elsewhere. Refresh Before Saving.");
      operation.assertCurrentAccount?.();
      return prior;
    }
    if (streams.some(stream => !stream.record.endedAt)) throw new Error("End Your Current Livestream Announcement Before Starting Another.");
  }
  return writeRecord(session, COLLECTION, record, operation, existing);
}
/** End the public metadata. The broadcaster must separately stop the encoder. */
export async function endLivestream(session: OAuthSession, stream: Livestream, operation: StreamOperation): Promise<Livestream> {
  ownKey(session, stream.uri);
  if (stream.record.endedAt) return stream;
  return writeRecord(session, COLLECTION, { ...stream.record, endedAt: operation.createdAt }, operation, stream);
}
export async function uploadStreamThumbnail(session: OAuthSession, file: Blob, assertCurrentAccount: () => void): Promise<StreamBlob> {
  if (!["image/jpeg", "image/png", "image/webp", "image/gif"].includes(file.type) || !file.size || file.size > 1_000_000) throw new Error("Use a PNG, JPEG, WebP or GIF image of at most 1 MB.");
  const bytes = new Uint8Array(await file.arrayBuffer());
  assertCurrentAccount(); const { data } = await createOAuthAgent(session).uploadBlob(bytes, { encoding: file.type }); assertCurrentAccount();
  return { $type: "blob", ref: { $link: data.blob.ref.toString() }, mimeType: data.blob.mimeType, size: data.blob.size };
}
export async function sendStreamChat(session: OAuthSession, streamer: string, text: string, operation: StreamOperation): Promise<void> {
  const value = text.trim(); if (!value || new RichText({ text: value }).graphemeLength > 300 || utf8(value).length > 3000 || !/^did:[^\s/?#]+$/.test(streamer)) throw new Error("Chat messages need 1–300 characters and a valid streamer.");
  await writeRecord(session, "place.stream.chat.message", { $type: "place.stream.chat.message", text: value, streamer, createdAt: operation.createdAt }, operation);
}
