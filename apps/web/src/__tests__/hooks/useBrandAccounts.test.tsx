import * as Tools from "@/lib/toolsEnabled";
import * as Pro from "@/hooks/useProEntitlements";
import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Sessions from "@/lib/brandAccounts/brandAccountSessions";
import * as Auth from "@/lib/auth";
import { useBrandAccounts, useBrandAccountSession } from "@/hooks/useBrandAccounts";

const restores: (() => void)[] = [];
let owner: string; let linked: string[];
let isPro = true;
beforeEach(() => {
  isPro = true;
  const entitlement = spyOn(Pro, "useProEntitlements").mockImplementation(() => ({ isPro }) as ReturnType<typeof Pro.useProEntitlements>); restores.push(() => entitlement.mockRestore());
  owner = "did:plc:owner"; linked = ["did:plc:brand", "did:plc:other"];
  const hint = spyOn(Auth, "getStoredOAuthDid").mockImplementation(() => owner); restores.push(() => hint.mockRestore());
  const list = spyOn(Sessions, "listBrandAccounts").mockImplementation(() => linked); restores.push(() => list.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
it("keeps linked OAuth in memory and rejects actor/unlink/primary owner changes before writes", async () => {
  const restore = spyOn(Sessions, "restoreBrandAccount").mockImplementation(async (_owner, brand) => ({ did: brand } as unknown as OAuthSession)); restores.push(() => restore.mockRestore());
  const { result, rerender } = renderHook(({ brand }) => useBrandAccountSession("did:plc:owner", brand), { initialProps: { brand: "did:plc:brand" } });
  await waitFor(() => expect(result.current.session?.did).toBe("did:plc:brand"));
  const oldGuard = result.current.assertCurrentActor;
  expect(() => oldGuard()).not.toThrow();
  rerender({ brand: "did:plc:other" }); expect(() => oldGuard()).toThrow("Changed"); expect(result.current.session).toBeUndefined();
  await waitFor(() => expect(result.current.session?.did).toBe("did:plc:other"));
  linked = []; expect(() => result.current.assertCurrentActor()).toThrow("Changed");
  linked = ["did:plc:other"]; owner = "did:plc:new-owner"; expect(() => result.current.assertCurrentActor()).toThrow("Changed");
});
it("discards a late restore from the previous brand and rejects old guards after unmount", async () => {
  let resolve!: (value: OAuthSession) => void;
  const restore = spyOn(Sessions, "restoreBrandAccount").mockImplementation(async (_owner, brand) => brand === "did:plc:brand" ? new Promise(done => { resolve = done; }) : { did: brand } as unknown as OAuthSession); restores.push(() => restore.mockRestore());
  const { result, rerender, unmount } = renderHook(({ brand }) => useBrandAccountSession("did:plc:owner", brand), { initialProps: { brand: "did:plc:brand" } });
  await waitFor(() => expect(resolve).toBeDefined()); rerender({ brand: "did:plc:other" });
  await waitFor(() => expect(result.current.session?.did).toBe("did:plc:other"));
  await act(async () => { resolve({ did: "did:plc:brand" } as unknown as OAuthSession); });
  expect(result.current.session?.did).toBe("did:plc:other"); const guard = result.current.assertCurrentActor; unmount(); expect(() => guard()).toThrow("Changed");
});
it("shows restore errors and retries without stale actor state", async () => {
  const restore = spyOn(Sessions, "restoreBrandAccount").mockRejectedValueOnce(new Error("Expired Authorization")).mockResolvedValue({ did: "did:plc:brand" } as unknown as OAuthSession); restores.push(() => restore.mockRestore());
  const { result } = renderHook(() => useBrandAccountSession("did:plc:owner", "did:plc:brand"));
  await waitFor(() => expect(result.current.error).toBe("Expired Authorization"));
  act(() => result.current.retry()); await waitFor(() => expect(result.current.session?.did).toBe("did:plc:brand")); expect(result.current.error).toBeUndefined();
});

it("hides linked accounts and never restores their sessions for Free viewers", async () => {
  isPro = false;
  const restore = spyOn(Sessions, "restoreBrandAccount").mockResolvedValue({ did: "did:plc:brand" } as unknown as OAuthSession); restores.push(() => restore.mockRestore());
  const { result } = renderHook(() => ({ accounts: useBrandAccounts("did:plc:owner"), actor: useBrandAccountSession("did:plc:owner", "did:plc:brand") }));
  await act(async () => {});
  expect(result.current.accounts).toEqual([]);
  expect(result.current.actor.session).toBeUndefined();
  expect(restore).not.toHaveBeenCalled();
  expect(() => result.current.actor.assertCurrentActor()).toThrow("Changed");
});
it("revokes a restored brand session and captured actor guard on downgrade", async () => {
  const restore = spyOn(Sessions, "restoreBrandAccount").mockResolvedValue({ did: "did:plc:brand" } as unknown as OAuthSession); restores.push(() => restore.mockRestore());
  const { result, rerender } = renderHook(() => useBrandAccountSession("did:plc:owner", "did:plc:brand"));
  await waitFor(() => expect(result.current.session?.did).toBe("did:plc:brand"));
  const previousGuard = result.current.assertCurrentActor;
  isPro = false;
  rerender();
  expect(result.current.session).toBeUndefined();
  expect(() => previousGuard()).toThrow("Changed");
  expect(() => result.current.assertCurrentActor()).toThrow("Changed");
});

it("does not expose or restore persisted brand identities when Tools is unavailable to a Pro viewer", () => {
  const gate = spyOn(Tools, "toolsEnabled").mockReturnValue(false); restores.push(() => gate.mockRestore());
  const restore = spyOn(Sessions, "restoreBrandAccount"); restores.push(() => restore.mockRestore());
  const { result } = renderHook(() => ({ accounts: useBrandAccounts(owner), actor: useBrandAccountSession(owner, "did:plc:brand") }));
  expect(result.current.accounts).toEqual([]);
  expect(result.current.actor.session).toBeUndefined();
  expect(Sessions.listBrandAccounts).not.toHaveBeenCalled();
  expect(restore).not.toHaveBeenCalled();
  expect(() => result.current.actor.assertCurrentActor()).toThrow();
});
