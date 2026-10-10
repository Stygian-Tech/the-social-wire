import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import { XRPCError } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { isMissingOAuthScope, SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { buildArticleNativeContent } from "./articleNativeContent";
import type { ArticleBlob, ArticleHost, ArticleImageAsset, ArticlePublication, ArticlePublishInput, ArticlePublishResult, ArticleRecord, PublishedArticle } from "./articlePublishingTypes";
export type { ArticleImageAsset, ArticlePublication, ArticlePublishInput, ArticlePublishResult, PublishedArticle } from "./articlePublishingTypes";
const DOCUMENT = "site.standard.document";
const PUBLICATION = "site.standard.publication";
const bytes = (text: string) => new TextEncoder().encode(text).length;
function key(uri: string, did: string, collection: string): string {
  const prefix = `at://${did}/${collection}/`;
  if (!uri.startsWith(prefix) || !/^[a-zA-Z0-9._~:-]+$/.test(uri.slice(prefix.length))) throw new Error("The article or publication does not belong to this account.");
  return uri.slice(prefix.length);
}
function siteUrl(value: unknown): string {
  if (typeof value !== "string") throw new Error("The publication has no HTTPS URL.");
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) throw new Error("The publication must have a valid HTTPS URL.");
  return url.href.replace(/\/$/, "");
}
export function articlePublicationHost(record: ArticleRecord): ArticleHost {
  const hint = JSON.stringify(record.theme ?? "").toLowerCase();
  for (const host of ["leaflet", "markpub", "offprint", "pckt"] as const) if (hint.includes(host)) return host;
  const hostname = new URL(siteUrl(record.url)).hostname.toLowerCase();
  for (const [host, domain] of [["leaflet", "leaflet.pub"], ["offprint", "offprint.app"], ["markpub", "markpub.at"], ["pckt", "pckt.blog"]] as const) if (hostname === domain || hostname.endsWith(`.${domain}`)) return host;
  return "unknown";
}
async function listOwned(session: OAuthSession, collection: string, signal?: AbortSignal): Promise<PublishedArticle[]> {
  const agent = createOAuthAgent(session), records: PublishedArticle[] = [], cursors = new Set<string>();
  let cursor: string | undefined;
  do {
    signal?.throwIfAborted();
    const { data } = await agent.com.atproto.repo.listRecords({ repo: session.did, collection, limit: 100, cursor }, { signal });
    signal?.throwIfAborted();
    for (const item of data.records) {
      key(item.uri, session.did, collection);
      if (!item.value || typeof item.value !== "object" || (item.value as ArticleRecord).$type !== collection) throw new Error("The PDS returned an invalid article record.");
      records.push({ uri: item.uri, cid: item.cid, record: item.value as ArticleRecord });
    }
    cursor = data.cursor;
    if (cursor && cursors.has(cursor)) throw new Error("The PDS repeated an article pagination cursor.");
    if (cursor) cursors.add(cursor);
  } while (cursor);
  return records;
}
export async function listArticlePublications(session: OAuthSession, signal?: AbortSignal): Promise<ArticlePublication[]> {
  return (await listOwned(session, PUBLICATION, signal)).filter(item => !item.uri.endsWith("/blento.self")).map(item => {
    if (typeof item.record.name !== "string" || !item.record.name.trim()) throw new Error("A publication has no name.");
    return { ...item, name: item.record.name, url: siteUrl(item.record.url), host: articlePublicationHost(item.record) };
  });
}
export async function listPublishedArticles(session: OAuthSession, signal?: AbortSignal): Promise<PublishedArticle[]> {
  return (await listOwned(session, DOCUMENT, signal)).sort((a, b) => String(b.record.publishedAt ?? "").localeCompare(String(a.record.publishedAt ?? "")));
}
async function uploadBlob(session: OAuthSession, body: Blob, signal?: AbortSignal): Promise<{ blob: ArticleBlob; url: string }> {
  signal?.throwIfAborted();
  const response = await session.fetchHandler("/xrpc/com.atproto.repo.uploadBlob", { method: "POST", headers: { "Content-Type": body.type }, body, signal });
  if (!response.ok) {
    const text = await response.text();
    let failure: { error?: unknown; message?: unknown } = {};
    try { failure = JSON.parse(text); } catch { /* Some PDS errors are plain text. */ }
    const challenge = response.headers.get("WWW-Authenticate");
    const message = typeof failure?.message === "string" ? failure.message : isMissingOAuthScope(challenge) ? challenge! : text || `Article asset upload failed (${response.status}).`;
    throw new XRPCError(response.status, typeof failure?.error === "string" ? failure.error : undefined, message, Object.fromEntries(response.headers));
  }
  const data = await response.json() as { blob: ArticleBlob };
  lexParse(JSON.stringify(data.blob), { strict: true });
  if (data.blob.$type !== "blob" || data.blob.mimeType !== body.type || data.blob.size !== body.size) throw new Error("The PDS returned mismatched article blob metadata.");
  const endpoint = new URL(response.url);
  if (endpoint.protocol !== "https:" && !(endpoint.protocol === "http:" && ["localhost", "127.0.0.1"].includes(endpoint.hostname))) throw new Error("The PDS returned an invalid upload origin.");
  const url = new URL("/xrpc/com.atproto.sync.getBlob", endpoint.origin);
  url.search = new URLSearchParams({ did: session.did, cid: data.blob.ref.$link }).toString();
  return { blob: data.blob, url: url.href };
}
export async function uploadArticleImage(session: OAuthSession, file: Blob, metadata: { alt: string; width: number; height: number }, signal?: AbortSignal): Promise<ArticleImageAsset> {
  if (!["image/png", "image/jpeg", "image/gif", "image/webp"].includes(file.type) || !file.size || file.size > 1_000_000) throw new Error("Article images must be PNG, JPEG, GIF, or WebP and at most 1 MB.");
  if (![metadata.width, metadata.height].every(value => Number.isSafeInteger(value) && value > 0)) throw new Error("Article images need valid pixel dimensions.");
  return { id: crypto.randomUUID(), ...await uploadBlob(session, file, signal), ...metadata };
}
function newKey(): string {
  const alphabet = "234567abcdefghijklmnopqrstuvwxyz";
  let value = (BigInt(Date.now()) * 1000n << 10n) | BigInt(crypto.getRandomValues(new Uint16Array(1))[0] & 1023);
  let result = "";
  for (let i = 0; i < 13; i++) { result = alphabet[Number(value & 31n)] + result; value >>= 5n; }
  return result;
}
/** Stable TID for a private draft: its creation instant plus deterministic clock bits. */
export async function articleDraftRecordKey(id: string, createdAt: string): Promise<string> {
  const timestamp = Date.parse(createdAt);
  if (!Number.isSafeInteger(timestamp) || timestamp <= 0) throw new Error("Invalid article draft creation date.");
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id)));
  const microOffset = ((digest[0] << 8) | digest[1]) % 1000;
  let value = ((BigInt(timestamp) * 1000n + BigInt(microOffset)) << 10n) | BigInt(((digest[2] << 8) | digest[3]) & 1023);
  if (value >= (1n << 63n)) throw new Error("Article draft creation date is outside the TID range.");
  const alphabet = "234567abcdefghijklmnopqrstuvwxyz";
  let result = "";
  for (let i = 0; i < 13; i++) { result = alphabet[Number(value & 31n)] + result; value >>= 5n; }
  return result;
}
function validateText(value: string, maxBytes: number, maxGraphemes: number, name: string) {
  if (bytes(value) > maxBytes || [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(value)].length > maxGraphemes) throw new Error(`${name} exceeds the standard document limit.`);
}
function articlePath(input: ArticlePublishInput, rkey: string): string {
  const raw = input.path.trim() || input.title.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "untitled-article";
  if (/[?#\\\u0000-\u0020]/.test(raw) || raw.split("/").some(part => part === ".." || part === ".")) throw new Error("Choose a relative article path without query parameters or traversal.");
  let path = `/${raw.replace(/^\/+/, "")}`;
  if (input.publication.host === "offprint" && !path.startsWith(`/a/${rkey}-`)) path = `/a/${rkey}-${path.replace(/^\/a\/[^-]+-/, "").replace(/^\//, "").replace(/[^a-zA-Z0-9-]+/g, "-")}`;
  if (input.publication.host === "pckt" && !input.existing) path += `-${rkey.slice(-7)}`;
  return path;
}
/** Called only by explicit Publish. Canonical and native wrapper writes are atomic. */
export async function publishArticle(session: OAuthSession, input: ArticlePublishInput, signal?: AbortSignal): Promise<ArticlePublishResult> {
  signal?.throwIfAborted();
  const publicationKey = key(input.publication.uri, session.did, PUBLICATION);
  if (!input.title.trim() || !input.markdown.trim()) throw new Error("An article needs a title and content.");
  validateText(input.title, 5000, 500, "Article title");
  validateText(input.description ?? "", 30000, 3000, "Article description");
  for (const tag of input.tags) validateText(tag, 1280, 128, "Article tag");
  if (bytes(input.markdown) > 1_000_000) throw new Error("Article Markdown exceeds 1 MB.");
  const agent = createOAuthAgent(session);
  const commit = await agent.com.atproto.sync.getLatestCommit({ did: session.did }, { signal });
  const publication = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: PUBLICATION, rkey: publicationKey }, { signal });
  if (publication.data.uri !== input.publication.uri || publication.data.cid !== input.publication.cid) throw new Error("The publication changed. Refresh before publishing.");
  const currentPub = publication.data.value as ArticleRecord;
  if (currentPub.$type !== PUBLICATION) throw new Error("Invalid publication record.");
  const url = siteUrl(currentPub.url), host = articlePublicationHost(currentPub);
  if (host !== input.publication.host) throw new Error("The publication host changed. Refresh before publishing.");
  const rkey = input.existing ? key(input.existing.uri, session.did, DOCUMENT) : input.recordKey ?? newKey();
  if (!/^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$/.test(rkey)) throw new Error("Article document keys must be valid TIDs.");
  const uri = `at://${session.did}/${DOCUMENT}/${rkey}`;
  if (!input.existing && input.recordKey) {
    let absent = false;
    try {
      await agent.com.atproto.repo.getRecord({ repo: session.did, collection: DOCUMENT, rkey }, { signal });
    } catch (error) {
      if (!(error && typeof error === "object" && "error" in error && error.error === "RecordNotFound")) throw error;
      // Only a canonical RecordNotFound response authorizes creation.
      absent = true;
    }
    if (!absent) throw new Error(`An article already exists at ${uri}. Check Published Articles before retrying.`);
  }
  let previous: ArticleRecord = {};
  if (input.existing) {
    const current = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: DOCUMENT, rkey }, { signal });
    if (current.data.cid !== input.existing.cid || current.data.uri !== uri) throw new Error("This article changed elsewhere. Reload before publishing.");
    previous = current.data.value as ArticleRecord;
    if (previous.site !== input.publication.uri) throw new Error("An existing article cannot move to another publication.");
  }
  let pcktSite: string | undefined;
  if (host === "pckt") {
    const pckt = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: "blog.pckt.publication", rkey: publicationKey }, { signal });
    const value = pckt.data.value as ArticleRecord, ref = value.publication as { uri?: string; cid?: string } | undefined;
    pcktSite = `at://${session.did}/blog.pckt.publication/${publicationKey}`;
    if (pckt.data.uri !== pcktSite || value.$type !== "blog.pckt.publication" || ref?.uri !== input.publication.uri || ref.cid !== publication.data.cid) throw new Error("The pckt publication does not reference this current standard publication.");
    const verification = await fetch(`${url}/.well-known/site.standard.publication`, { signal, credentials: "omit", redirect: "error" });
    if (!verification.ok || (await verification.text()).trim() !== input.publication.uri) throw new Error("The pckt site could not verify this publication.");
  }
  const native = buildArticleNativeContent(host, input.markdown, input.bodyAssets ?? [], input.description), content = native.content;
  if (host === "markpub" || host === "unknown") {
    const text = content.text as ArticleRecord;
    if (bytes(String(text.markdown)) > 100 * 1024) { text.textBlob = (await uploadBlob(session, new Blob([String(text.markdown)], { type: "text/markdown" }), signal)).blob; text.markdown = String(text.markdown).slice(0, 1000); }
  } else if (host === "leaflet" && bytes(JSON.stringify(content.pages)) > 100 * 1024) {
    content.blobPages = (await uploadBlob(session, new Blob([JSON.stringify(content.pages)], { type: "application/json" }), signal)).blob; content.pages = []; content.blobs = [];
  } else if (host === "pckt" && bytes(JSON.stringify(content.items)) > 20_000) {
    content.blob = (await uploadBlob(session, new Blob([JSON.stringify(content.items)], { type: "application/json" }), signal)).blob; delete content.items; content.references = [];
  } else if (host === "offprint" && bytes(JSON.stringify(content)) >= 900_000) throw new Error("Offprint article content exceeds its record size limit.");
  const now = new Date().toISOString(), path = articlePath(input, rkey);
  const record: ArticleRecord = { ...previous, $type: DOCUMENT, site: input.publication.uri, title: input.title.trim(), publishedAt: previous.publishedAt ?? now, updatedAt: now, path, content, textContent: native.textContent };
  delete record.description; delete record.coverImage; delete record.tags;
  if (input.description?.trim()) record.description = input.description.trim();
  if (input.cover) record.coverImage = input.cover.blob;
  if (input.tags.length || host === "pckt") record.tags = [...new Set(input.tags.map(tag => tag.trim()).filter(Boolean))];
  if (host === "pckt") record.langs = ["en"];
  const cid = (await cidForLex(lexParse(JSON.stringify(record), { strict: true }))).toString();
  const writes: { $type: "com.atproto.repo.applyWrites#create" | "com.atproto.repo.applyWrites#update"; collection: string; rkey: string; value: ArticleRecord }[] = [{ $type: `com.atproto.repo.applyWrites#${input.existing ? "update" : "create"}`, collection: DOCUMENT, rkey, value: record }];
  let wrapperUri: string | undefined;
  if (host === "offprint" || host === "pckt") {
    const collection = host === "offprint" ? "app.offprint.document.article" : "blog.pckt.document";
    if (input.existing && !input.existing.wrapperUri) throw new Error("Load the native article wrapper before updating this article.");
    const wrapperKey = input.existing?.wrapperUri ? key(input.existing.wrapperUri, session.did, collection) : rkey;
    wrapperUri = `at://${session.did}/${collection}/${wrapperKey}`;
    if (host === "pckt" && wrapperKey !== rkey) throw new Error("The pckt wrapper must share the canonical document key.");
    if (input.existing) {
      const wrapper = await agent.com.atproto.repo.getRecord({ repo: session.did, collection, rkey: wrapperKey }, { signal });
      const ref = (wrapper.data.value as ArticleRecord).document as { uri?: string; cid?: string } | undefined;
      if (wrapper.data.cid !== input.existing.wrapperCid || ref?.uri !== uri || ref.cid !== input.existing.cid) throw new Error("The native article wrapper changed. Reload before publishing.");
    }
    writes.push({ $type: `com.atproto.repo.applyWrites#${input.existing ? "update" : "create"}`, collection, rkey: wrapperKey, value: { $type: collection, document: { ...(host === "offprint" ? { $type: "com.atproto.repo.strongRef" } : {}), uri, cid }, ...(pcktSite ? { site: pcktSite } : {}) } });
  }
  signal?.throwIfAborted();
  const wrapperCid = writes[1] ? (await cidForLex(lexParse(JSON.stringify(writes[1].value), { strict: true }))).toString() : undefined;
  const published = { uri, cid, wrapperUri, wrapperCid, url: `${url}${path}` };
  try {
    const response = await agent.com.atproto.repo.applyWrites({ repo: session.did, writes, swapCommit: commit.data.cid }, { signal });
    const result = response.data.results?.[0], wrapperResult = response.data.results?.[1];
    if (!result || !("uri" in result) || result.uri !== uri || result.cid !== cid || (wrapperUri && (!wrapperResult || !("uri" in wrapperResult) || wrapperResult.uri !== wrapperUri || wrapperResult.cid !== wrapperCid))) throw new Error("Unexpected PDS commit response.");
    return published;
  } catch (error) {
    // An explicit PDS rejection cannot have committed this atomic operation.
    // Preserve its identity so authorization recovery can recognize the scope.
    if (error && typeof error === "object" && "status" in error && typeof error.status === "number" && error.status >= 400 && error.status < 500) throw error;
    if (isMissingOAuthScope(error) || (error instanceof Error && error.message === SCOPE_RECOVERY_MESSAGE)) throw error;
    // A dropped response does not prove a failed write. Verify the exact records;
    // never repeat a mutation automatically or generate another article identity.
    try {
      const canonical = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: DOCUMENT, rkey }, { signal });
      if (canonical.data.uri !== uri || canonical.data.cid !== cid) throw new Error("Unconfirmed document.");
      if (writes[1]) {
        const wrapper = await agent.com.atproto.repo.getRecord({ repo: session.did, collection: writes[1].collection, rkey: writes[1].rkey }, { signal });
        if (wrapper.data.uri !== wrapperUri || wrapper.data.cid !== wrapperCid) throw new Error("Unconfirmed wrapper.");
      }
      return published;
    } catch {
      throw new Error(`Publishing could not be confirmed at ${uri}. Check Published Articles before retrying.`, { cause: error });
    }
  }
}
