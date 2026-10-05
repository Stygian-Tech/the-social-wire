import { afterEach, expect, it } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { consumeOAuthReturnPath, isMissingOAuthScope, observeOAuthScopeErrors, onOAuthScopeRecovery, SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

const originalEnv = process.env.NEXT_PUBLIC_APP_ENV;
afterEach(() => { if (originalEnv === undefined) delete process.env.NEXT_PUBLIC_APP_ENV; else process.env.NEXT_PUBLIC_APP_ENV = originalEnv; window.sessionStorage.clear(); });
const missing = 'Missing required scope "repo:app.thesocialwire.sports.selection?action=create"';
function fakeSession(fetchHandler: (url: string, init?: RequestInit) => Promise<Response>) { return { did: "did:plc:test", fetchHandler } as unknown as OAuthSession; }

it("recognizes scope failures without treating ordinary auth or network errors as scope failures", () => {
  expect(isMissingOAuthScope(new Error(missing))).toBe(true);
  expect(isMissingOAuthScope({ error: "insufficient_scope" })).toBe(true);
  expect(isMissingOAuthScope(new Error("Forbidden"))).toBe(false);
  expect(isMissingOAuthScope(null)).toBe(false);
});
it("retains exact diagnostics and response in Development", async () => {
  process.env.NEXT_PUBLIC_APP_ENV = "dev";
  const session = observeOAuthScopeErrors(fakeSession(async () => new Response(JSON.stringify({message: missing}), {status:403})));
  const response = await session.fetchHandler("/xrpc/com.atproto.repo.putRecord");
  expect((await response.json()).message).toBe(missing);
});
it("prompts in Production for any scope and never replays a mutation", async () => {
  process.env.NEXT_PUBLIC_APP_ENV = "prod";
  let calls = 0;
  const dids: string[] = [];
  const remove = onOAuthScopeRecovery(did => dids.push(did));
  try {
    const session = fakeSession(async () => { calls++; return new Response(JSON.stringify({message:'Missing required scope "repo:app.standard-reader.list?action=delete"'}), {status:403}); });
    observeOAuthScopeErrors(session); observeOAuthScopeErrors(session);
    await expect(session.fetchHandler("/xrpc/com.atproto.repo.deleteRecord", {method:"POST"})).rejects.toThrow(SCOPE_RECOVERY_MESSAGE);
    expect(calls).toBe(1); expect(dids).toEqual(["did:plc:test"]);
  } finally { remove(); }
});
it("handles SDK-thrown scope failures and protocol scope challenges", async () => {
  process.env.NEXT_PUBLIC_APP_ENV = "prod";
  const session = observeOAuthScopeErrors(fakeSession(async () => { throw new Error(missing); }));
  await expect(session.fetchHandler("/xrpc/write")).rejects.toThrow(SCOPE_RECOVERY_MESSAGE);
  const challenged = observeOAuthScopeErrors(fakeSession(async () => new Response(null, {status:403, headers:{"WWW-Authenticate":'DPoP error="insufficient_scope"'}})));
  await expect(challenged.fetchHandler("/xrpc/write")).rejects.toThrow(SCOPE_RECOVERY_MESSAGE);
  const plain = observeOAuthScopeErrors(fakeSession(async () => new Response(missing, {status:400})));
  await expect(plain.fetchHandler("/xrpc/write")).rejects.toThrow(SCOPE_RECOVERY_MESSAGE);
});
it("preserves nonce responses, ordinary failures and successful recovery without notifying", async () => {
  process.env.NEXT_PUBLIC_APP_ENV = "prod";
  let notified = false;
  const remove = onOAuthScopeRecovery(() => { notified = true; });
  try {
    const nonce = observeOAuthScopeErrors(fakeSession(async () => new Response(null,{status:401, headers:{"DPoP-Nonce":"nonce"}})));
    expect((await nonce.fetchHandler("/xrpc/write")).status).toBe(401);
    const error = new Error("Network failed");
    const failed = observeOAuthScopeErrors(fakeSession(async () => {throw error;}));
    await expect(failed.fetchHandler("/xrpc/write")).rejects.toBe(error);
    const recovered = observeOAuthScopeErrors(fakeSession(async () => new Response("ok")));
    expect(await (await recovered.fetchHandler("/xrpc/write")).text()).toBe("ok");
    expect(notified).toBe(false);
  } finally {remove();}
});
it("restores only same-origin reader navigation once, not attacker URLs", () => {
  window.sessionStorage.setItem("the-social-wire.oauth-return-path.v1", "/read?feed=sports#selection");
  expect(consumeOAuthReturnPath()).toBe("/read?feed=sports#selection");
  expect(consumeOAuthReturnPath()).toBe("/read");
  for (const value of ["//evil.example", "/\\evil.example", "/callback", "https://evil.example"]) {
    window.sessionStorage.setItem("the-social-wire.oauth-return-path.v1",value); expect(consumeOAuthReturnPath()).toBe("/read");
  }
});
