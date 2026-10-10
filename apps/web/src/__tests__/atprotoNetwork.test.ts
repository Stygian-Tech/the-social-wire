import { afterEach, describe, expect, it } from "bun:test";
import { buildAtprotoLoopbackClientId } from "@atproto/oauth-types";
import { Agent } from "@atproto/api";
import { resolveAtprotoNetwork, atprotoScopesForNetwork, localLoopbackOAuthScopes, authorizationScopesForClient } from "@/lib/atprotoNetwork";
import { AT_PROTO_OAUTH_SCOPES } from "@/lib/atprotoOAuthScopes";
import { LocalAppViewAgent } from "@/lib/localAppViewAgent";
import { getBlueskySocialCatalog } from "@/lib/blueskySocialClient";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { isDummyReaderDataEnabled } from "@/lib/dummyReaderData";
const original = { app: process.env.NEXT_PUBLIC_APP_ENV, dummy: process.env.NEXT_PUBLIC_USE_DUMMY_DATA };
afterEach(() => {
  if (original.app === undefined) delete process.env.NEXT_PUBLIC_APP_ENV;
  else process.env.NEXT_PUBLIC_APP_ENV = original.app;
  if (original.dummy === undefined) delete process.env.NEXT_PUBLIC_USE_DUMMY_DATA;
  else process.env.NEXT_PUBLIC_USE_DUMMY_DATA = original.dummy;
});
const local = { publicAppView: "https://appview.atmosbox.test", plcDirectory: "https://plc.atmosbox.test", handleResolver: "https://pds1.atmosbox.test", appViewDid: "did:web:appview.atmosbox.test", appLabelers: "" };
describe("local ATProto network", () => {
  it("selects the explicit local endpoints and empty app labelers", () => {
    expect(resolveAtprotoNetwork("local", local)).toEqual({ ...local, appLabelers: [], chatServiceDid: undefined });
    expect(resolveAtprotoNetwork("local").appLabelers).toBeUndefined();
  });
  it("ignores even invalid overrides outside explicit local mode", () => {
    for (const env of ["", "prod", "production", "dev", "test"]) expect(resolveAtprotoNetwork(env, { ...local, publicAppView: "invalid" })).toEqual(resolveAtprotoNetwork("prod"));
  });
  it("rejects unsafe endpoints and invalid DIDs", () => {
    for (const publicAppView of ["http://appview.atmosbox.test", "https://user:secret@appview.atmosbox.test", "https://appview.atmosbox.test/path", "https://appview.atmosbox.test/?x=1"]) expect(() => resolveAtprotoNetwork("local", { publicAppView })).toThrow();
    expect(() => resolveAtprotoNetwork("local", { appViewDid: "invalid" })).toThrow();
    expect(() => resolveAtprotoNetwork("local", { appLabelers: "invalid" })).toThrow();
  });
  it("aligns all AppView audiences while preserving repository permissions", () => {
    const scopes = atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, resolveAtprotoNetwork("local", local));
    expect(scopes).not.toContain("did:web:api.bsky.app");
    expect(scopes).toContain("rpc:app.bsky.feed.getTimeline?aud=did:web:appview.atmosbox.test%23bsky_appview");
    expect(scopes).toContain("rpc:app.bsky.feed.getFeedSkeleton?aud=did:web:appview.atmosbox.test%23bsky_appview");
    expect(scopes).toContain("include:app.bsky.authCreatePosts?aud=did:web:appview.atmosbox.test%23bsky_appview");
    expect(scopes.split(" ").filter(s => s.startsWith("repo:"))).toEqual(AT_PROTO_OAUTH_SCOPES.split(" ").filter(s => s.startsWith("repo:")));
    expect(atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, resolveAtprotoNetwork("prod"))).toBe(AT_PROTO_OAUTH_SCOPES);
  });
  it("compacts only full repo actions in the explicit local loopback client ID", () => {
    const scopes = "repo:app.example.full?action=create&action=update&action=delete repo:app.example.partial?action=create&action=delete rpc:app.example.method?aud=did:web:app.example include:app.example.authFull";
    const compact = localLoopbackOAuthScopes(scopes, "local");
    expect(compact).toBe("repo:app.example.full repo:app.example.partial?action=create&action=delete rpc:app.example.method?aud=did:web:app.example include:app.example.authFull");
    for (const env of ["prod", "dev", "", "test"]) expect(localLoopbackOAuthScopes(scopes, env)).toBe(scopes);
    const aligned = atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, resolveAtprotoNetwork("local", local));
    const clientId = buildAtprotoLoopbackClientId({ redirect_uris: ["http://127.0.0.1:3016/callback"], scope: localLoopbackOAuthScopes(aligned, "local") });
    const authorize = new URL("https://pds1.atmosbox.test/oauth/authorize");
    const declared = new URL(clientId).searchParams.get("scope")!.split(" ");
    const requested = authorizationScopesForClient(aligned, clientId, "local").split(" ");
    expect(requested.every(scope => declared.includes(scope))).toBe(true);
    expect(authorizationScopesForClient(aligned, "https://socialwire.atmosbox.internal/oauth-client-metadata.json", "local")).toBe(aligned);
    authorize.searchParams.set("client_id", clientId);
    authorize.searchParams.set("request_uri", `urn:ietf:params:oauth:request_uri:${"x".repeat(64)}`);
    expect(authorize.href.length).toBeLessThan(4096);
    expect(encodeURIComponent(aligned).length - encodeURIComponent(localLoopbackOAuthScopes(aligned, "local")).length).toBeGreaterThan(1000);
  });

  it("groups exact RPC permissions without wildcard access or cross-service methods", () => {
    const input = "rpc:app.example.one?aud=did:web:app.example%23view rpc:app.example.two?aud=did:web:app.example%23view rpc:chat.example.read?aud=did:web:chat.example%23chat";
    const compact = localLoopbackOAuthScopes(input, "local");
    expect(compact).toBe("rpc?aud=did:web:app.example%23view&lxm=app.example.one&lxm=app.example.two rpc:chat.example.read?aud=did:web:chat.example%23chat");
    expect(compact).not.toContain("*");
    expect(localLoopbackOAuthScopes(input, "dev")).toBe(input);
  });
  it("keeps local chat isolated and rewrites only a configured chat audience", () => {
    const network = resolveAtprotoNetwork("local", local);
    expect(network.chatServiceDid).toBeUndefined();
    expect(atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, network)).not.toContain("api.bsky.chat");
    const configured = resolveAtprotoNetwork("local", { ...local, chatServiceDid: "did:web:chat.atmosbox.test" });
    expect(atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, configured)).toContain("did:web:chat.atmosbox.test%23bsky_chat");
    expect(resolveAtprotoNetwork("dev", { ...local, chatServiceDid: "invalid" }).chatServiceDid).toBe("did:web:api.bsky.chat");
    expect(() => resolveAtprotoNetwork("local", { ...local, chatServiceDid: "invalid" })).toThrow();
  });

  it("retains subscribed labelers in local clones without mutating global safety", () => {
    const agent = new LocalAppViewAgent(local.publicAppView, []);
    agent.configureLabelers(["did:web:labeler.atmosbox.test"]);
    const clone = agent.withProxy("bsky_appview", local.appViewDid);
    expect(clone.appLabelers).toEqual([]);
    expect(clone.labelers).toEqual(["did:web:labeler.atmosbox.test"]);
    expect(new Agent("https://public.api.bsky.app").appLabelers.length).toBeGreaterThan(0);
  });
  it("loads local preferences without an external labeler and keeps local subscriptions fail-closed", async () => {
    const previous = { did: process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APPVIEW_DID, labelers: process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APP_LABELERS };
    process.env.NEXT_PUBLIC_APP_ENV = "local";
    process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APPVIEW_DID = local.appViewDid;
    process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APP_LABELERS = "";
    try {
      let subscribed = false;
      const session = {
        did: "did:plc:alice",
        fetchHandler: async (path: string, init?: RequestInit) => {
          expect(new Headers(init?.headers).get("atproto-proxy")).toBe(`${local.appViewDid}#bsky_appview`);
          expect(new Headers(init?.headers).get("atproto-accept-labelers")).not.toContain("did:plc:ar7c4by46qjdydhdevvrndac");
          const request = new URL(path, "https://pds1.atmosbox.test");
          if (request.pathname.endsWith("getServices")) {
            // A real AppView rejects an empty DID array; local no-labeler catalogs must skip this RPC.
            expect(request.searchParams.getAll("dids").length).toBeGreaterThan(0);
            return Response.json({ views: [] });
          }
          return Response.json({ preferences: subscribed ? [{ $type: "app.bsky.actor.defs#labelersPref", labelers: [{ did: "did:web:labeler.atmosbox.test" }] }] : [] });
        },
      } as unknown as OAuthSession;
      expect((await getBlueskySocialCatalog(session)).moderation.prefs.labelers).toEqual([]);
      subscribed = true;
      await expect(getBlueskySocialCatalog(session)).rejects.toThrow("moderation settings");
    } finally {
      if (previous.did === undefined) delete process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APPVIEW_DID;
      else process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APPVIEW_DID = previous.did;
      if (previous.labelers === undefined) delete process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APP_LABELERS;
      else process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APP_LABELERS = previous.labelers;
    }
  });
  it("lets explicit false disable dummy local sessions", () => {
    process.env.NEXT_PUBLIC_APP_ENV = "local";
    delete process.env.NEXT_PUBLIC_USE_DUMMY_DATA;
    expect(isDummyReaderDataEnabled()).toBe(true);
    process.env.NEXT_PUBLIC_USE_DUMMY_DATA = "false";
    expect(isDummyReaderDataEnabled()).toBe(false);
    process.env.NEXT_PUBLIC_USE_DUMMY_DATA = "true";
    expect(isDummyReaderDataEnabled()).toBe(true);
  });
});
