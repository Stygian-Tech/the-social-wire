import { describe, expect, test } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { CHUNK_COLLECTION, MANIFEST_COLLECTION, ReadStateError, commitIntent, recordCID } from "@thesocialwire/read-state";
import { OAuthReadStateRepository } from "@/lib/pdsReadStateRepository";

describe("authenticated PDS read-state transport", () => {
  test("uses the OAuth session PDS transport and CAS guards for chunks and manifest", async () => {
    const requests: Record<string, unknown>[] = [];
    const oauth = { did: "did:plc:alice", fetchHandler: async (_url: URL, init?: RequestInit) => {
      if (!init?.method || init.method.toUpperCase() === "GET") return Response.json({ error: "RecordNotFound", message: "Not found" }, { status: 400 });
      const body = JSON.parse(await new Response(init?.body).text()) as Record<string, unknown>;
      requests.push(body);
      return Response.json({ uri: `at://did:plc:alice/${body.collection}/${body.rkey}`, cid: await recordCID(body.record) });
    } } as unknown as OAuthSession;
    const repository = new OAuthReadStateRepository(oauth, () => {});
    await commitIntent(repository, { actionId: "action", state: "read", actedAt: "2026-09-08T12:00:00Z", selection: "exact", subjectUris: ["article"] });
    expect(requests.map(request => request.collection)).toEqual([CHUNK_COLLECTION, MANIFEST_COLLECTION]);
    expect(requests.every(request => request.repo === oauth.did && request.swapRecord === null)).toBe(true);
    expect(requests[1].rkey).toBe("self");
  });
  test("sign-out invalidates a captured session before any PDS request", async () => {
    let requests = 0;
    const oauth = { did: "did:plc:alice", fetchHandler: async () => { requests++; return Response.json({}); } } as unknown as OAuthSession;
    const repository = new OAuthReadStateRepository(oauth, () => { throw new ReadStateError("reauthorize"); });
    await expect(repository.getRecord(MANIFEST_COLLECTION, "self")).rejects.toThrow("reauthorize");
    expect(requests).toBe(0);
  });
  test("converts PDS throttling into retry metadata rather than a false missing record", async () => {
    const oauth = { did: "did:plc:alice", fetchHandler: async () => Response.json(
      { error: "RateLimitExceeded", message: "Slow down" }, { status: 429, headers: { "retry-after": "120" } }) } as unknown as OAuthSession;
    const repository = new OAuthReadStateRepository(oauth, () => {});
    try { await repository.getRecord(MANIFEST_COLLECTION, "self"); throw new Error("Expected rejection"); }
    catch (error) { expect(error).toMatchObject({ status: 429, retryAfter: "120" }); }
  });
});
