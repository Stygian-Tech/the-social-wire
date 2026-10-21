import { compactLoopbackClientId } from "@/lib/atprotoNetwork";
import { skejScopesForEnvironment } from "@/lib/skej/skejEnvironment";
import { afterEach, describe, expect, it } from "bun:test";
import { atprotoLoopbackClientMetadata, buildAtprotoLoopbackClientId } from "@atproto/oauth-types";
import { isAtprotoOauthScope, RepoPermission, RpcPermission, ScopePermissions } from "@atproto/oauth-scopes";
import { BRAND_ACCOUNT_OAUTH_SCOPES } from "@/lib/brandAccounts/brandAccountScopes";
import { Agent } from "@atproto/api";
import { resolveAtprotoNetwork, atprotoScopesForNetwork, localLoopbackOAuthScopes, authorizationScopesForClient } from "@/lib/atprotoNetwork";
import { AT_PROTO_OAUTH_SCOPES, BLUESKY_PODCAST_VIDEO_SCOPES } from "@/lib/atprotoOAuthScopes";
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
  it("omits unsupported public video delegation only for the isolated sandbox", () => {
    const isolated = atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, resolveAtprotoNetwork("local", local));
    for (const scope of BLUESKY_PODCAST_VIDEO_SCOPES) expect(isolated.split(" ")).not.toContain(scope);
    for (const env of ["prod", "dev"]) {
      const hosted = atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, resolveAtprotoNetwork(env, local));
      for (const scope of BLUESKY_PODCAST_VIDEO_SCOPES) expect(hosted.split(" ")).toContain(scope);
    }
    expect(isolated).toContain("repo:app.bsky.feed.post?action=create");
  });
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
    expect(scopes).toContain("repo:app.bsky.feed.post?action=create");
    expect(scopes.split(" ").filter(s => s.startsWith("repo:"))).toEqual(AT_PROTO_OAUTH_SCOPES.split(" ").filter(s => s.startsWith("repo:")));
    expect(atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, resolveAtprotoNetwork("prod"))).toBe(skejScopesForEnvironment(AT_PROTO_OAUTH_SCOPES));
  });
  it("keeps the local loopback client within the URL budget with identical metadata and PAR scopes", () => {
    const scopes = "repo:app.example.full?action=create&action=update&action=delete repo:app.example.partial?action=create&action=delete rpc:app.example.method?aud=did:web:app.example include:app.example.authFull";
    const compact = localLoopbackOAuthScopes(scopes, "local");
    expect(compact).toBe("repo:app.example.full repo:app.example.partial?action=create&action=delete rpc:app.example.method?aud=did:web:app.example include:app.example.authFull");
    for (const env of ["prod", "dev", "", "test"]) expect(localLoopbackOAuthScopes(scopes, env)).toBe(scopes);
    const aligned = atprotoScopesForNetwork(AT_PROTO_OAUTH_SCOPES, resolveAtprotoNetwork("local", local));
    const clientId = compactLoopbackClientId(buildAtprotoLoopbackClientId({ redirect_uris: ["http://127.0.0.1:3016/callback"], scope: localLoopbackOAuthScopes(aligned, "local") }));
    const authorize = new URL("https://pds1.atmosbox.test/oauth/authorize");
    const declared = new URL(clientId).searchParams.get("scope")!.split(" ");
    const requested = authorizationScopesForClient(aligned, clientId, "local").split(" ");
    expect(requested).toEqual(declared);
    expect(requested.join(" ")).toBe(atprotoLoopbackClientMetadata(clientId).scope);
    expect(authorizationScopesForClient(aligned, "https://socialwire.atmosbox.internal/oauth-client-metadata.json", "local")).toBe(aligned);
    authorize.searchParams.set("client_id", clientId);
    authorize.searchParams.set("request_uri", `urn:ietf:params:oauth:request_uri:${"x".repeat(64)}`);
    expect(aligned).not.toContain("rpc:com.atproto.moderation.createReport");
    expect(aligned).toContain("repo:app.bsky.graph.block?action=create&action=delete");
    expect(authorize.href.length).toBeLessThan(4096);
    expect(encodeURIComponent(aligned).length - encodeURIComponent(localLoopbackOAuthScopes(aligned, "local")).length).toBeGreaterThan(1000);
  });

  it("groups only identical repo action sets when the encoding is smaller", () => {
    const scopes = [
      "repo:app.example.first?action=create&action=update",
      "repo:app.example.second?action=update&action=create",
      "repo:app.example.first?action=create&action=update",
      "repo:app.example.single?action=create",
      "repo:app.example.delete?action=delete",
      "repo:app.example.full?action=create&action=update&action=delete",
      "repo:app.example.future?action=create&action=update&future=restriction",
      "repo:app.example.unknown?action=unknown",
    ];
    const compact = localLoopbackOAuthScopes(scopes.join(" "), "local");
    expect(compact).toContain("repo?collection=app.example.first&collection=app.example.second&action=create&action=update");
    for (const scope of [scopes[3], scopes[4], scopes[6], scopes[7]]) expect(compact.split(" ")).toContain(scope);
    expect(compact.split(" ")).toContain("repo:app.example.full");
    expect(localLoopbackOAuthScopes(compact, "local")).toBe(compact);
    const permissions = new ScopePermissions(compact);
    expect(permissions.allowsRepo({ collection: "app.example.first", action: "update" })).toBe(true);
    expect(permissions.allowsRepo({ collection: "app.example.first", action: "delete" })).toBe(false);
    expect(permissions.allowsRepo({ collection: "app.example.single", action: "update" })).toBe(false);
    expect(permissions.allowsRepo({ collection: "app.example.delete", action: "create" })).toBe(false);
  });

  it("preserves the complete permission matrix for Web and brand loopback clients", () => {
    for (const network of [resolveAtprotoNetwork("local", local), resolveAtprotoNetwork("local")]) {
      for (const scopes of [AT_PROTO_OAUTH_SCOPES, BRAND_ACCOUNT_OAUTH_SCOPES]) {
        const input = atprotoScopesForNetwork(scopes, network).split(" ");
        const output = localLoopbackOAuthScopes(input.join(" "), "local").split(" ");
        expect(output.every(isAtprotoOauthScope)).toBe(true);
        const before = new ScopePermissions(input);
        const after = new ScopePermissions(output);
        const repo = [...input, ...output].flatMap(scope => RepoPermission.fromString(scope)?.collection ?? []);
        for (const collection of [...new Set(repo), "app.example.ungranted"]) {
          for (const action of ["create", "update", "delete"] as const) {
            expect(after.allowsRepo({ collection, action })).toBe(before.allowsRepo({ collection, action }));
          }
        }
        const rpc = [...input, ...output].flatMap(scope => {
          const permission = RpcPermission.fromString(scope);
          return permission ? [{ aud: permission.aud, methods: permission.lxm }] : [];
        });
        const audiences = new Set([...rpc.map(permission => permission.aud), "did:web:ungranted.example#service"]);
        const methods = new Set([...rpc.flatMap(permission => permission.methods), "app.example.ungranted"]);
        for (const aud of audiences) {
          for (const lxm of methods) expect(after.allowsRpc({ aud, lxm })).toBe(before.allowsRpc({ aud, lxm }));
        }
        const other = (scope: string) => !scope.startsWith("repo") && !scope.startsWith("rpc");
        expect(output.filter(other)).toEqual(input.filter(other));
      }
    }
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

it("compacts only safe loopback query characters without changing consent metadata", () => {
  const original = buildAtprotoLoopbackClientId({ redirect_uris: ["http://127.0.0.1:3016/callback"], scope: "atproto repo:app.example.record?action=create&action=delete rpc:at.skej.schedule.list?aud=did:web:api.skej.at%23skej_scheduler" });
  const compact = compactLoopbackClientId(original);
  expect([...new URL(compact).searchParams]).toEqual([...new URL(original).searchParams]);
  expect(new URL(compact).searchParams.get("scope")).toContain("%23skej_scheduler");
  expect(compactLoopbackClientId("https://example.com/path%2Fvalue")).toBe("https://example.com/path%2Fvalue");
});
