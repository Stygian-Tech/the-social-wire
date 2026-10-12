import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { OAuthClient, type OAuthSession } from "@atproto/oauth-client-browser";
import { atprotoLoopbackClientMetadata, buildAtprotoLoopbackClientId } from "@atproto/oauth-types";
import { indexedDB } from "fake-indexeddb";
import * as Auth from "@/lib/auth";
import * as Pro from "@/lib/proEntitlements";
import { BrandAwareOAuthClient } from "@/lib/brandAccounts/BrandAwareOAuthClient";
import { addBrandAccount, assertBrandAccountAvailable, BRAND_LINK_STATE_PREFIX, cancelBrandLinkIntent, completeBrandLinkIntent, createBrandLinkIntent, listBrandAccounts, onBrandAccountsChanged } from "@/lib/brandAccounts/brandAccountStorage";
import { linkBrandAccount, restoreBrandAccount, unlinkBrandAccount } from "@/lib/brandAccounts/brandAccountSessions";
const owner = "did:plc:owner", brand = "did:plc:brand", hint = "@@atproto/oauth-client-browser(sub)";
const restores: (() => void)[] = [];
const clients: BrandAwareOAuthClient[] = [];
beforeEach(() => {
  window.localStorage.clear(); window.sessionStorage.clear();
  for (const [key, value] of Object.entries({ localStorage: window.localStorage, sessionStorage: window.sessionStorage, indexedDB })) { const prior = Object.getOwnPropertyDescriptor(globalThis, key); Object.defineProperty(globalThis, key, { configurable: true, value }); restores.push(() => { if (prior) Object.defineProperty(globalThis, key, prior); else Reflect.deleteProperty(globalThis, key); }); }
  window.localStorage.setItem(hint, owner);
  const entitlement = spyOn(Pro, "requirePro").mockResolvedValue(undefined);
  const personal = spyOn(Auth, "getSession").mockResolvedValue({ did: owner } as unknown as OAuthSession);
  restores.push(() => entitlement.mockRestore(), () => personal.mockRestore());
});
afterEach(async () => { for (const client of clients.splice(0)) await client[Symbol.asyncDispose](); restores.splice(0).reverse().forEach(restore => restore()); window.localStorage.clear(); window.sessionStorage.clear(); });
function clientFixture(sub = brand) {
  const client = new BrandAwareOAuthClient({ handleResolver: "https://bsky.social", clientMetadata: atprotoLoopbackClientMetadata(buildAtprotoLoopbackClientId({ redirect_uris: ["http://127.0.0.1:3016/callback"], scope: "atproto" })) }, () => Auth.getStoredOAuthDid()); clients.push(client);
  const intent = createBrandLinkIntent(owner, client.clientMetadata.client_id), state = BRAND_LINK_STATE_PREFIX + intent.nonce;
  const del = mock(async (_key: string) => { void _key; });
  Object.defineProperty(client, "stateStore", { value: { get: async () => ({ appState: state, iss: "https://pds.example.com", authMethod: "none", verifier: "verifier", dpopKey: {} }), del } });
  const revokeNew = mock(async (_token: string) => { void _token; }), exchange = mock(async () => ({ sub, access_token: "new-test-token", refresh_token: "new-test-refresh" }));
  Object.defineProperty(client, "serverFactory", { value: { fromIssuer: async () => ({ issuer: "https://pds.example.com", serverMetadata: { authorization_response_iss_parameter_supported: true }, clientMetadata: client.clientMetadata, authMethod: "none", exchangeCode: exchange, revoke: revokeNew }) } });
  const stored = mock(async (_did: string, _value: unknown) => { void _did; void _value; }); Object.defineProperty(client, "sessionGetter", { value: { setStored: stored } });
  const revokeOld = spyOn(client, "revoke").mockResolvedValue(undefined); restores.push(() => revokeOld.mockRestore());
  const create = spyOn(client as unknown as { createSession: () => OAuthSession }, "createSession").mockReturnValue({ did: sub } as unknown as OAuthSession); restores.push(() => create.mockRestore());
  const restore = spyOn(OAuthClient.prototype, "restore").mockResolvedValue({ did: owner } as unknown as OAuthSession); restores.push(() => restore.mockRestore());
  return { client, intent, state, stored, revokeNew, revokeOld, exchange, del, params: new URLSearchParams({ state: "opaque-sdk-state", code: "test-code", iss: "https://pds.example.com" }) };
}
test("validated additive callback stores only brand credentials without routing personal account", async () => {
  const f = clientFixture(); const result = await f.client.callback(f.params);
  expect(result.state).toBe(f.state); expect(f.stored).toHaveBeenCalledTimes(1); expect(f.stored.mock.calls[0]![0]).toBe(brand); expect(f.revokeOld).toHaveBeenCalledWith(brand); expect(Auth.getStoredOAuthDid()).toBe(owner);
  expect(completeBrandLinkIntent(result.state, result.session.did, owner)).toBe(true); expect(listBrandAccounts(owner)).toEqual([brand]); expect(listBrandAccounts("did:plc:other")).toEqual([]);
});
test("provider selecting personal account never revokes or replaces its existing session", async () => {
  const f = clientFixture(owner); await expect(f.client.callback(f.params)).rejects.toThrow("Different Account");
  expect(f.revokeOld).not.toHaveBeenCalled(); expect(f.stored).not.toHaveBeenCalled(); expect(f.revokeNew).toHaveBeenCalledWith("new-test-refresh"); expect(Auth.getStoredOAuthDid()).toBe(owner); expect(f.del).toHaveBeenCalledTimes(1);
});
test("account change or expired intent rejects before code exchange", async () => {
  const f = clientFixture(); window.localStorage.setItem(hint, "did:plc:other"); await expect(f.client.callback(f.params)).rejects.toThrow("Personal Account Changed"); expect(f.exchange).not.toHaveBeenCalled(); expect(f.stored).not.toHaveBeenCalled();
});
test("registry is private to its owner and another owner cannot share SDK DID tokens", async () => {
  addBrandAccount("did:plc:other", brand); const f = clientFixture(); await expect(f.client.callback(f.params)).rejects.toThrow("Another Personal Account"); expect(f.stored).not.toHaveBeenCalled(); expect(f.revokeOld).not.toHaveBeenCalled();
  expect(listBrandAccounts(owner)).toEqual([]); expect(() => assertBrandAccountAvailable(owner, brand)).toThrow("Another Personal Account");
});
test("explicit linked restoration and unlink use core methods without changing personal hint", async () => {
  addBrandAccount(owner, brand);
  const client = {} as BrandAwareOAuthClient;
  const get = spyOn(Auth, "getOAuthClientForScopes").mockResolvedValue(client); restores.push(() => get.mockRestore());
  const restore = spyOn(OAuthClient.prototype, "restore").mockResolvedValue({ did: brand, fetchHandler: async () => Response.json({}) } as unknown as OAuthSession); restores.push(() => restore.mockRestore());
  const session = await restoreBrandAccount(owner, brand); expect(session.did).toBe(brand); expect(restore).toHaveBeenCalledWith(brand); expect(Auth.getStoredOAuthDid()).toBe(owner);
  const changed = mock(() => {}); const dispose = onBrandAccountsChanged(changed); restores.push(dispose);
  const revoke = spyOn(OAuthClient.prototype, "revoke").mockImplementation(async did => { expect(did).toBe(brand); expect(listBrandAccounts(owner)).toEqual([]); throw new Error("Revocation Unavailable"); }); restores.push(() => revoke.mockRestore());
  await expect(unlinkBrandAccount(owner, brand)).rejects.toThrow("Revocation Unavailable"); expect(changed).toHaveBeenCalledTimes(1); expect(Auth.getStoredOAuthDid()).toBe(owner);
  await expect(unlinkBrandAccount(owner, owner)).rejects.toThrow("Only A Linked");
});
test("link nonce, expiry and corrupted registry fail closed", () => {
  const intent = createBrandLinkIntent(owner, "https://example.com/client-metadata.json"); expect(() => completeBrandLinkIntent(BRAND_LINK_STATE_PREFIX + "wrong-nonce", brand, owner)).toThrow("Expired");
  window.sessionStorage.setItem("the-social-wire.brand-link.v1", JSON.stringify({ ...intent, expiresAt: Date.now() - 1 })); expect(() => completeBrandLinkIntent(BRAND_LINK_STATE_PREFIX + intent.nonce, brand, owner)).toThrow("Expired"); cancelBrandLinkIntent();
  window.localStorage.setItem("the-social-wire.brand-accounts.v1:" + owner, "not-json"); expect(listBrandAccounts(owner)).toEqual([]); expect(() => addBrandAccount(owner, brand)).toThrow(); expect(window.localStorage.getItem("the-social-wire.brand-accounts.v1:" + owner)).toBe("not-json");
});
test("invalidating linked brand leaves personal routing untouched", () => { Auth.invalidateOAuthSession(brand, new Error("Expired")); expect(Auth.getStoredOAuthDid()).toBe(owner); Auth.invalidateOAuthSession(owner, new Error("Expired")); expect(Auth.getStoredOAuthDid()).toBeNull(); });
test("normal callback retains sign-in routing and brand loopback metadata is an exact least-scope client", async () => {
  const previousEnv = process.env.NEXT_PUBLIC_APP_ENV; process.env.NEXT_PUBLIC_APP_ENV = "local"; restores.push(() => { if (previousEnv === undefined) delete process.env.NEXT_PUBLIC_APP_ENV; else process.env.NEXT_PUBLIC_APP_ENV = previousEnv; });
  const loader = spyOn(BrandAwareOAuthClient, "loadForAccounts").mockImplementation(async ({ clientId }) => ({ clientMetadata: atprotoLoopbackClientMetadata(clientId), findRedirectUrl: () => "http://127.0.0.1:3016/callback", callback: async () => ({ session: { did: "did:plc:normal" }, state: null }) }) as unknown as BrandAwareOAuthClient); restores.push(() => loader.mockRestore());
  window.history.replaceState(null, "", "/callback?state=normal-state&code=test-code");
  restores.push(() => window.history.replaceState(null, "", "/"));
  expect((await Auth.handleCallback()).did).toBe("did:plc:normal"); expect(Auth.getStoredOAuthDid()).toBe("did:plc:normal"); expect(Auth.consumeOAuthCallbackDestination()).toBeNull(); expect(window.location.search).toBe("");
  const { BRAND_ACCOUNT_OAUTH_SCOPES } = await import("@/lib/brandAccounts/brandAccountScopes");
  const { authorizationScopesForClient, atprotoScopesForNetwork } = await import("@/lib/atprotoNetwork");
  const linked = await Auth.getOAuthClientForScopes(BRAND_ACCOUNT_OAUTH_SCOPES);
  const requested = authorizationScopesForClient(atprotoScopesForNetwork(BRAND_ACCOUNT_OAUTH_SCOPES), linked.clientMetadata.client_id);
  expect(requested.split(" ").every(scope => linked.clientMetadata.scope!.split(" ").includes(scope))).toBe(true);
  expect(linked.clientMetadata.scope).not.toContain("thesocialwire.folder"); expect(linked.clientMetadata.scope).not.toContain("site.standard.document");
  expect(linked.clientMetadata.client_id).not.toBe(loader.mock.calls[0]![0].clientId);
});
test("owner switch during code exchange rejects new grant before storing or revoking old tokens", async () => {
  const f = clientFixture(); f.exchange.mockImplementation(async () => { window.localStorage.setItem(hint, "did:plc:other"); return { sub: brand, access_token: "new-test-token", refresh_token: "new-test-refresh" }; });
  await expect(f.client.callback(f.params)).rejects.toThrow("Personal Account Changed"); expect(f.stored).not.toHaveBeenCalled(); expect(f.revokeOld).not.toHaveBeenCalled(); expect(f.revokeNew).toHaveBeenCalledWith("new-test-refresh");
});

test("present empty issuer rejects before token exchange", async () => { const f = clientFixture(); f.params.set("iss", ""); await expect(f.client.callback(f.params)).rejects.toThrow("Issuer Mismatch"); expect(f.exchange).not.toHaveBeenCalled(); expect(f.stored).not.toHaveBeenCalled(); });

test("Free owners cannot link or restore a brand session", async () => {
  addBrandAccount(owner, brand);
  const denied = spyOn(Pro, "requirePro").mockRejectedValue(new Error(Pro.PRO_REQUIRED_MESSAGE));
  const client = spyOn(Auth, "getOAuthClientForScopes").mockResolvedValue({} as BrandAwareOAuthClient);
  restores.push(() => denied.mockRestore(), () => client.mockRestore());
  await expect(linkBrandAccount(owner, "brand.example.com")).rejects.toThrow(Pro.PRO_REQUIRED_MESSAGE);
  await expect(restoreBrandAccount(owner, brand)).rejects.toThrow(Pro.PRO_REQUIRED_MESSAGE);
  expect(client).not.toHaveBeenCalled();
  expect(listBrandAccounts(owner)).toEqual([brand]);
});

test("Free additive callback rejects before exchanging a grant", async () => {
  const f = clientFixture();
  const denied = spyOn(Pro, "requirePro").mockRejectedValue(new Error(Pro.PRO_REQUIRED_MESSAGE)); restores.push(() => denied.mockRestore());
  await expect(f.client.callback(f.params)).rejects.toThrow(Pro.PRO_REQUIRED_MESSAGE);
  expect(f.exchange).not.toHaveBeenCalled(); expect(f.stored).not.toHaveBeenCalled(); expect(f.revokeOld).not.toHaveBeenCalled();
});

test("entitlement loss during callback revokes the new grant without replacing credentials", async () => {
  const f = clientFixture();
  const access = spyOn(Pro, "requirePro").mockResolvedValueOnce(undefined).mockRejectedValueOnce(new Error(Pro.PRO_REQUIRED_MESSAGE)); restores.push(() => access.mockRestore());
  await expect(f.client.callback(f.params)).rejects.toThrow(Pro.PRO_REQUIRED_MESSAGE);
  expect(f.exchange).toHaveBeenCalledTimes(1); expect(f.stored).not.toHaveBeenCalled(); expect(f.revokeOld).not.toHaveBeenCalled(); expect(f.revokeNew).toHaveBeenCalledWith("new-test-refresh");
});

test("owner change during Pro lookup prevents brand session restoration", async () => {
  addBrandAccount(owner, brand);
  const access = spyOn(Pro, "requirePro").mockImplementation(async () => { window.localStorage.setItem(hint, "did:plc:other"); });
  const restore = spyOn(OAuthClient.prototype, "restore").mockResolvedValue({ did: brand } as unknown as OAuthSession);
  restores.push(() => access.mockRestore(), () => restore.mockRestore());
  await expect(restoreBrandAccount(owner, brand)).rejects.toThrow("Personal Account Changed"); expect(restore).not.toHaveBeenCalled();
});

test("Free owners can still unlink and revoke existing brand credentials", async () => {
  addBrandAccount(owner, brand);
  const denied = spyOn(Pro, "requirePro").mockRejectedValue(new Error(Pro.PRO_REQUIRED_MESSAGE));
  const client = spyOn(Auth, "getOAuthClientForScopes").mockResolvedValue({} as BrandAwareOAuthClient);
  const revoke = spyOn(OAuthClient.prototype, "revoke").mockResolvedValue(undefined);
  restores.push(() => denied.mockRestore(), () => client.mockRestore(), () => revoke.mockRestore());
  await unlinkBrandAccount(owner, brand);
  expect(listBrandAccounts(owner)).toEqual([]); expect(revoke).toHaveBeenCalledWith(brand); expect(denied).not.toHaveBeenCalled();
});
