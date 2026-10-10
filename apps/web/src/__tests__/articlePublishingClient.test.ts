import { afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import { XRPCError, type Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { cidForLex } from "@atproto/lex-cbor";
import { lexParse } from "@atproto/lex-json";
import * as Atproto from "@/lib/atprotoClient";
import { articleDraftRecordKey, articlePublicationHost, listArticlePublications, listPublishedArticles, publishArticle, uploadArticleImage } from "@/lib/articles/articlePublishingClient";
import { articleRichText, buildArticleNativeContent } from "@/lib/articles/articleNativeContent";
import type { ArticleHost, ArticleImageAsset, ArticlePublication, ArticlePublishInput, ArticleRecord } from "@/lib/articles/articlePublishingTypes";
import { socialErrorMessage } from "@/lib/blueskySocialClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
const did = "did:plc:viewer", session = { did } as unknown as OAuthSession;
const restores: (() => void)[] = [];
afterEach(() => restores.splice(0).reverse().forEach(fn => fn()));
function publication(host: ArticleHost = "offprint"): ArticlePublication {
  const record = { $type: "site.standard.publication", name: "Journal", url: "https://journal.test", theme: { $type: `${host}.theme` } };
  return { uri: `at://${did}/site.standard.publication/site`, cid: "pub-cid", name: "Journal", url: record.url, host, record };
}
function input(host: ArticleHost = "offprint"): ArticlePublishInput { return { publication: publication(host), title: "An Article", markdown: "# Heading\n\nHello **world**.", path: "/an-article", tags: ["testing"] }; }
function agent(pub = publication()) {
  const get = mock(async (params: { repo: string; collection: string; rkey: string }) => { void params; return { data: { uri: pub.uri, cid: pub.cid, value: pub.record } }; });
  const list = mock(async (params: { repo: string; collection: string; limit?: number; cursor?: string }, opts: unknown) => { void params; void opts; return { data: { records: [{ uri: pub.uri, cid: pub.cid, value: pub.record }], cursor: undefined as string | undefined } }; });
  const apply = mock(async (params: { writes: { collection: string; rkey: string; value: ArticleRecord }[]; swapCommit?: string }) => ({ data: { results: await Promise.all(params.writes.map(async write => ({ uri: `at://${did}/${write.collection}/${write.rkey}`, cid: (await cidForLex(lexParse(JSON.stringify(write.value), { strict: true }))).toString() }))) } }));
  const latest = mock(async () => ({ data: { cid: "snapshot-cid" } }));
  const spy = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ com: { atproto: { repo: { getRecord: get, listRecords: list, applyWrites: apply }, sync: { getLatestCommit: latest } } } } as unknown as Agent);
  restores.push(() => spy.mockRestore());
  return { get, list, apply, latest };
}
const blob = { $type: "blob" as const, ref: { $link: "bafkreie3zvlvg43mywvbvld32d7sk6xkgvjphhhgtjgwqhzfmvf6xnuw2m" }, mimeType: "image/png", size: 3 };
const asset: ArticleImageAsset = { id: "image", blob, width: 640, height: 480, alt: "An image", url: "https://pds.test/xrpc/com.atproto.sync.getBlob?cid=example" };
describe("native article content", () => {
  it("counts rich facet ranges in UTF-8 plaintext and rejects unsafe link facets", () => {
    const rich = articleRichText("😀 **é** and [safe](https://example.com) [bad](javascript:alert)", "pub.leaflet.richtext.facet");
    expect(rich.plaintext).toBe("😀 é and safe bad");
    expect(rich.facets).toEqual([{ index: { byteStart: 5, byteEnd: 7 }, features: [{ $type: "pub.leaflet.richtext.facet#bold" }] }, { index: { byteStart: 12, byteEnd: 16 }, features: [{ $type: "pub.leaflet.richtext.facet#link", uri: "https://example.com" }] }]);
  });
  it("uses Leaflet pages, headings, code, checked lists and native image blobs", () => {
    const result = buildArticleNativeContent("leaflet", "# Title\n\n- [x] Done\n  - Child\n\n```TS\nconst a = 1\n```\n\n![Caption](article-asset://image)", [asset]);
    const pages = result.content.pages as { blocks: { block: ArticleRecord }[] }[];
    expect(pages[0].blocks.map(b => b.block.$type)).toEqual(["pub.leaflet.blocks.header", "pub.leaflet.blocks.unorderedList", "pub.leaflet.blocks.code", "pub.leaflet.blocks.image"]);
    const list = pages[0].blocks[1].block.children as ArticleRecord[];
    expect(list[0].checked).toBe(true);
    expect(list[0].children).toHaveLength(1);
    expect(pages[0].blocks[2].block).toMatchObject({ plaintext: "const a = 1", language: "ts" });
    expect(pages[0].blocks[3].block).toMatchObject({ image: blob, aspectRatio: { width: 640, height: 480 } });
  });
  it("maps Offprint heading bounds and pckt image attrs, summary, and trailing paragraph", () => {
    const offprint = buildArticleNativeContent("offprint", "###### Heading", []);
    expect((offprint.content.items as ArticleRecord[])[0]).toMatchObject({ $type: "app.offprint.block.heading", level: 3 });
    const pckt = buildArticleNativeContent("pckt", "![Caption](article-asset://image)", [asset], "Summary");
    const items = pckt.content.items as ArticleRecord[];
    expect(items[0]).toMatchObject({ $type: "blog.pckt.block.heading", level: 3, plaintext: "Summary" });
    expect(items[1]).toMatchObject({ attrs: { src: `blob:${blob.ref.$link}`, blob, align: "center" } });
    expect(items.at(-1)).toMatchObject({ $type: "blog.pckt.block.text", plaintext: "" });
  });
  it("resolves Markpub asset links and fails missing/native remote images", () => {
    const result = buildArticleNativeContent("unknown", "![x](article-asset://image)", [asset]);
    expect(result.content).toMatchObject({ $type: "at.markpub.markdown", text: { markdown: `![x](${asset.url})` } });
    expect(() => buildArticleNativeContent("leaflet", "![x](article-asset://missing)", [])).toThrow("not been uploaded");
    expect(() => buildArticleNativeContent("offprint", "![x](https://remote.test/a.png)", [])).toThrow("Upload remote");
    expect(articleRichText("++Underlined++ ~~Removed~~ `literal **bold**`", "app.offprint.richtext.facet")).toMatchObject({ plaintext: "Underlined Removed literal **bold**", facets: [{ index: { byteStart: 0, byteEnd: 10 }, features: [{ $type: "app.offprint.richtext.facet#underline" }] }, { index: { byteStart: 11, byteEnd: 18 }, features: [{ $type: "app.offprint.richtext.facet#strikethrough" }] }, { index: { byteStart: 19, byteEnd: 35 }, features: [{ $type: "app.offprint.richtext.facet#code" }] }] });
  });
});
describe("direct PDS article publishing", () => {
  it("derives stable canonical TIDs with distinct same-millisecond draft identities", async () => {
    const createdAt = "2026-10-10T12:00:00.123Z";
    const first = await articleDraftRecordKey("draft-1", createdAt);
    expect(first).toMatch(/^[234567abcdefghij][234567abcdefghijklmnopqrstuvwxyz]{12}$/);
    expect(await articleDraftRecordKey("draft-1", createdAt)).toBe(first);
    expect(await articleDraftRecordKey("draft-2", createdAt)).not.toBe(first);
    await expect(articleDraftRecordKey("x", "invalid")).rejects.toThrow("creation date");
  });
  it("discovers only owned publications, identifies host, preserves unknown custom domains", async () => {
    const calls = agent(publication("leaflet"));
    const signal = new AbortController().signal;
    expect((await listArticlePublications(session, signal))[0].host).toBe("leaflet");
    expect(calls.list.mock.calls[0]).toEqual([{ repo: did, collection: "site.standard.publication", limit: 100, cursor: undefined }, { signal }]);
    expect(articlePublicationHost({ url: "https://notleaflet.pub" })).toBe("unknown");
    calls.list.mockResolvedValueOnce({ data: { records: [{ uri: "at://did:plc:other/site.standard.publication/site", cid: "x", value: publication().record }], cursor: undefined } });
    await expect(listArticlePublications(session)).rejects.toThrow("does not belong");
  });
  it("propagates unsupported reads, cancellation and repeated cursor failure", async () => {
    const calls = agent();
    calls.list.mockRejectedValueOnce(new Error("MethodNotImplemented"));
    await expect(listArticlePublications(session)).rejects.toThrow("MethodNotImplemented");
    calls.list.mockResolvedValue({ data: { records: [], cursor: "repeat" } });
    await expect(listPublishedArticles(session)).rejects.toThrow("repeated");
    const controller = new AbortController(); controller.abort();
    await expect(listArticlePublications(session, controller.signal)).rejects.toThrow();
  });
  it("atomically creates Offprint canonical and wrapper with exact CID and swapCommit", async () => {
    const calls = agent();
    const result = await publishArticle(session, input());
    expect(calls.apply).toHaveBeenCalledTimes(1);
    const write = calls.apply.mock.calls[0][0];
    expect(write.swapCommit).toBe("snapshot-cid");
    expect(write.writes).toHaveLength(2);
    expect(write.writes[0].value).toMatchObject({ $type: "site.standard.document", site: publication().uri, title: "An Article", tags: ["testing"] });
    expect(write.writes[1].value.document).toEqual({ $type: "com.atproto.repo.strongRef", uri: result.uri, cid: result.cid });
    expect(result.url).toMatch(/^https:\/\/journal.test\/a\/[a-z2-7]+-an-article$/);
  });
  it("fails changed publications and stale updates without writes", async () => {
    const calls = agent();
    await expect(publishArticle(session, { ...input(), publication: { ...publication(), cid: "old" } })).rejects.toThrow("publication changed");
    expect(calls.apply).not.toHaveBeenCalled();
    calls.get.mockImplementation(async params => params.collection === "site.standard.publication" ? { data: { uri: publication().uri, cid: publication().cid, value: publication().record } } : { data: { uri: `at://${did}/site.standard.document/3m4abcdefghij`, cid: "new-cid", value: { ...publication().record, site: publication().uri } } });
    await expect(publishArticle(session, { ...input(), existing: { uri: `at://${did}/site.standard.document/3m4abcdefghij`, cid: "old-cid", record: {} } })).rejects.toThrow("changed elsewhere");
    expect(calls.apply).not.toHaveBeenCalled();
  });
  it("rejects empty articles, cross-account targets, and unsafe paths", async () => {
    const calls = agent();
    await expect(publishArticle(session, { ...input(), markdown: "" })).rejects.toThrow("title and content");
    await expect(publishArticle(session, { ...input(), publication: { ...publication(), uri: "at://did:plc:other/site.standard.publication/site" } })).rejects.toThrow("does not belong");
    await expect(publishArticle(session, { ...input(), path: "/../escape" })).rejects.toThrow("relative article path");
    expect(calls.apply).not.toHaveBeenCalled();
  });
  it("validates image formats/dimensions and returns viewer-PDS blob URL", async () => {
    const fetchHandler = mock(async () => {
      const response = Response.json({ blob }); Object.defineProperty(response, "url", { value: "https://pds.test/xrpc/com.atproto.repo.uploadBlob" }); return response;
    });
    const authenticated = { did, fetchHandler } as unknown as OAuthSession;
    const signal = new AbortController().signal;
    const image = await uploadArticleImage(authenticated, new Blob(["abc"], { type: "image/png" }), { alt: "Picture", width: 100, height: 50 }, signal);
    expect(image.blob).toEqual(blob);
    expect(image.url).toContain("https://pds.test/xrpc/com.atproto.sync.getBlob?did=did%3Aplc%3Aviewer");
    expect(fetchHandler.mock.calls[0]).toHaveLength(2);
    await expect(uploadArticleImage(authenticated, new Blob(["abc"], { type: "image/svg+xml" }), { alt: "x", width: 1, height: 1 })).rejects.toThrow("PNG");
    await expect(uploadArticleImage(authenticated, new Blob(["abc"], { type: "image/png" }), { alt: "x", width: 0, height: 1 })).rejects.toThrow("dimensions");
    expect(fetchHandler).toHaveBeenCalledTimes(1);
  });
  it("confirms an ambiguous committed write and prevents a retry from creating another record", async () => {
    const calls = agent(publication("markpub"));
    const recordKey = await articleDraftRecordKey("draft-id", "2026-10-10T12:00:00Z");
    let committed: { uri: string; cid: string; value: ArticleRecord } | undefined;
    calls.get.mockImplementation(async params => {
      if (params.collection === "site.standard.publication") return { data: { uri: publication("markpub").uri, cid: "pub-cid", value: publication("markpub").record } };
      if (committed) return { data: committed };
      throw Object.assign(new Error("Missing"), { error: "RecordNotFound" });
    });
    calls.apply.mockImplementation(async params => {
      const write = params.writes[0];
      committed = { uri: `at://${did}/${write.collection}/${write.rkey}`, cid: (await cidForLex(lexParse(JSON.stringify(write.value), { strict: true }))).toString(), value: write.value };
      throw new Error("Network response lost after commit");
    });
    const result = await publishArticle(session, { ...input("markpub"), recordKey });
    expect(result.uri).toBe(`at://${did}/site.standard.document/${recordKey}`);
    await expect(publishArticle(session, { ...input("markpub"), recordKey })).rejects.toThrow("already exists");
    expect(calls.apply).toHaveBeenCalledTimes(1);
  });
  it("reports an uncertain URI if commit confirmation fails, without retrying the mutation", async () => {
    const calls = agent(publication("markpub"));
    calls.apply.mockRejectedValueOnce(new Error("Offline"));
    await expect(publishArticle(session, input("markpub"))).rejects.toThrow("Publishing could not be confirmed at at://");
    expect(calls.apply).toHaveBeenCalledTimes(1);
  });
  it("preserves definite authorization rejections for permission recovery without reconciliation", async () => {
    const calls = agent(publication("markpub"));
    const rejection = new XRPCError(403, "InsufficientScope", "Missing required scope: repo:site.standard.document?action=create");
    calls.apply.mockRejectedValueOnce(rejection);
    const error = await publishArticle(session, input("markpub")).catch(error => error);
    expect(error).toBe(rejection);
    expect(socialErrorMessage(error)).toBe(SCOPE_RECOVERY_MESSAGE);
    expect(calls.get).toHaveBeenCalledTimes(1);
    expect(calls.apply).toHaveBeenCalledTimes(1);
  });
  it("preserves explicit validation failures while still reconciling server failures", async () => {
    const calls = agent(publication("markpub"));
    const rejection = new XRPCError(400, "InvalidRecord", "Article record is invalid");
    calls.apply.mockRejectedValueOnce(rejection);
    await expect(publishArticle(session, input("markpub"))).rejects.toBe(rejection);
    expect(calls.get).toHaveBeenCalledTimes(1);
    calls.apply.mockRejectedValueOnce(new XRPCError(503, "InternalServerError", "Upstream unavailable"));
    await expect(publishArticle(session, input("markpub"))).rejects.toThrow("could not be confirmed");
    expect(calls.get).toHaveBeenCalledTimes(3);
  });
  it("preserves upload error status and scope details from JSON or authentication headers", async () => {
    const fetchHandler = mock(async () => Response.json({ error: "InsufficientScope", message: "Missing required scope: blob:image/png" }, { status: 403 }));
    const authenticated = { did, fetchHandler } as unknown as OAuthSession;
    const upload = () => uploadArticleImage(authenticated, new Blob(["abc"], { type: "image/png" }), { alt: "Picture", width: 100, height: 50 });
    const error = await upload().catch(error => error);
    expect(error).toBeInstanceOf(XRPCError);
    expect(error.status).toBe(403);
    expect(error.error).toBe("InsufficientScope");
    expect(socialErrorMessage(error)).toBe(SCOPE_RECOVERY_MESSAGE);
    fetchHandler.mockResolvedValueOnce(new Response("Forbidden", { status: 403, headers: { "WWW-Authenticate": 'Bearer error="insufficient_scope"' } }));
    const headerError = await upload().catch(error => error);
    expect(headerError.status).toBe(403);
    expect(socialErrorMessage(headerError)).toBe(SCOPE_RECOVERY_MESSAGE);
    expect(fetchHandler).toHaveBeenCalledTimes(2);
  });
  it("verifies pckt publication ownership and writes its same-key wrapper", async () => {
    const pub = publication("pckt"), calls = agent(pub);
    calls.get.mockImplementation(async params => params.collection === "site.standard.publication" ? { data: { uri: pub.uri, cid: pub.cid, value: pub.record } } : { data: { uri: `at://${did}/blog.pckt.publication/site`, cid: "pckt-pub", value: { $type: "blog.pckt.publication", publication: { uri: pub.uri, cid: pub.cid } } as ArticleRecord } });
    const verification = spyOn(globalThis, "fetch").mockResolvedValue(new Response(pub.uri));
    restores.push(() => verification.mockRestore());
    const result = await publishArticle(session, input("pckt"));
    const writes = calls.apply.mock.calls[0][0].writes;
    expect(writes[1].rkey).toBe(writes[0].rkey);
    expect(writes[1].value).toMatchObject({ $type: "blog.pckt.document", document: { uri: result.uri, cid: result.cid }, site: `at://${did}/blog.pckt.publication/site` });
    expect(verification.mock.calls[0][1]).toMatchObject({ credentials: "omit", redirect: "error" });
    verification.mockResolvedValueOnce(new Response("at://someone-else/site.standard.publication/site"));
    await expect(publishArticle(session, input("pckt"))).rejects.toThrow("could not verify");
    expect(calls.apply).toHaveBeenCalledTimes(1);
  });
  it("offloads large Markdown as a text blob and keeps canonical plaintext", async () => {
    const calls = agent(publication("markpub"));
    const fetchHandler = mock(async (_path: string, init?: RequestInit) => {
      const body = init!.body as Blob;
      const response = Response.json({ blob: { ...blob, mimeType: body.type, size: body.size } });
      Object.defineProperty(response, "url", { value: "https://pds.test/xrpc/com.atproto.repo.uploadBlob" }); return response;
    });
    const authenticated = { did, fetchHandler } as unknown as OAuthSession;
    await publishArticle(authenticated, { ...input("markpub"), markdown: `# Heading\n\n${"text ".repeat(25000)}` });
    const record = calls.apply.mock.calls[0][0].writes[0].value;
    expect(record.textContent).toStartWith("Heading\n\ntext ");
    expect(record.content).toMatchObject({ text: { textBlob: { mimeType: "text/markdown" } } });
    expect(fetchHandler).toHaveBeenCalledTimes(1);
  });
  it("preserves publication time and unknown fields when updating the expected revision", async () => {
    const pub = publication("markpub"), calls = agent(pub), uri = `at://${did}/site.standard.document/3m4abcdefghij`;
    const prior = { $type: "site.standard.document", site: pub.uri, publishedAt: "2025-01-01T00:00:00Z", custom: { preserved: true }, description: "Old", tags: ["old"] };
    calls.get.mockImplementation(async params => params.collection === "site.standard.publication" ? { data: { uri: pub.uri, cid: pub.cid, value: pub.record } } : { data: { uri, cid: "old-cid", value: prior } });
    await publishArticle(session, { ...input("markpub"), tags: [], existing: { uri, cid: "old-cid", record: prior } });
    const write = calls.apply.mock.calls[0][0].writes[0];
    expect(write.value).toMatchObject({ publishedAt: prior.publishedAt, custom: prior.custom });
    expect(write.value.description).toBeUndefined();
    expect(write.value.tags).toBeUndefined();
  });
  it("validates canonical text limits before any PDS request", async () => {
    const calls = agent();
    await expect(publishArticle(session, { ...input(), title: "x".repeat(501) })).rejects.toThrow("title exceeds");
    await expect(publishArticle(session, { ...input(), description: "x".repeat(3001) })).rejects.toThrow("description exceeds");
    await expect(publishArticle(session, { ...input(), tags: ["x".repeat(129)] })).rejects.toThrow("tag exceeds");
    expect(calls.latest).not.toHaveBeenCalled();
  });
});
