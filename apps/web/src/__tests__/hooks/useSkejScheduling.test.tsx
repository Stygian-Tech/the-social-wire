import * as Publishing from "@/lib/articles/articlePublishingClient";
import * as Preparation from "@/lib/articles/articleSchedulingPreparation";
import { ArticleSchedulingNotSubmittedError } from "@/lib/articles/articleSchedulingError";
import * as Entitlements from "@/lib/proEntitlements";
import * as Pro from "@/hooks/useProEntitlements";
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Accounts from "@/hooks/useBrandAccounts";
import * as Sessions from "@/lib/brandAccounts/brandAccountSessions";
import * as Stored from "@/lib/auth";
import * as Client from "@/lib/skej/skejSchedulingClient";
import { useSkejScheduling } from "@/hooks/useSkejScheduling";

const owner = "did:plc:owner", brand = "did:plc:brand";
const personal = { did: owner } as unknown as OAuthSession, linked = { did: brand } as unknown as OAuthSession;
let cache: QueryClient;
let registered = true;
const restores: (() => void)[] = [];
let isPro = true;
beforeEach(() => {
  isPro = true;
  const entitlement = spyOn(Pro, "useProEntitlements").mockImplementation(() => ({ isPro }) as ReturnType<typeof Pro.useProEntitlements>); restores.push(() => entitlement.mockRestore());
  const access = spyOn(Entitlements, "requirePro").mockImplementation(async () => { if (!isPro) throw new Error(Entitlements.PRO_REQUIRED_MESSAGE); }); restores.push(() => access.mockRestore());
  registered = true;
  cache = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did: owner }, getOAuthSession: () => personal } as ReturnType<typeof Auth.useAuth>); restores.push(() => auth.mockRestore());
  const accounts = spyOn(Accounts, "useBrandAccounts").mockReturnValue([brand]); restores.push(() => accounts.mockRestore());
  const hint = spyOn(Stored, "getStoredOAuthDid").mockReturnValue(owner); restores.push(() => hint.mockRestore());
  const registry = spyOn(Sessions, "listBrandAccounts").mockImplementation(() => registered ? [brand] : []); restores.push(() => registry.mockRestore());
  const restore = spyOn(Sessions, "restoreBrandAccount").mockResolvedValue(linked); restores.push(() => restore.mockRestore());
  const readiness = spyOn(Client, "getSkejSchedulingReadiness").mockImplementation(async actor => { actor.assertCurrentActor(); return { accountDid: actor.session.did, connected: true }; }); restores.push(() => readiness.mockRestore());
  const list = spyOn(Client, "listSkejSchedules").mockResolvedValue([]); restores.push(() => list.mockRestore());
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function wrapper({ children }: { children: React.ReactNode }) { return <QueryClientProvider client={cache}>{children}</QueryClientProvider>; }

test("uses the selected brand session, and refuses writes after unlink without personal fallback", async () => {
  const create = spyOn(Client, "createSkejSchedule").mockImplementation(async actor => { actor.assertCurrentActor(); return {} as Client.SkejScheduleSummary; }); restores.push(() => create.mockRestore());
  const { result } = renderHook(() => useSkejScheduling(owner, brand), { wrapper });
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  await act(async () => { await result.current.schedule("Brand Content", "2099-01-01T12:00:00Z"); });
  expect(create.mock.calls[0][0].session).toBe(linked);
  expect(result.current.connectUrl).toContain(encodeURIComponent(brand));
  registered = false;
  await act(async () => { await expect(result.current.schedule("Removed Account", "2099-01-01T12:00:00Z")).rejects.toThrow("No Longer Linked"); });
  expect(create).toHaveBeenCalledTimes(1);
});
test("rejects a deferred write when the acting account changes before commit", async () => {
  const { result, rerender } = renderHook(({ actor }) => useSkejScheduling(owner, actor, { includeSchedules: false }), { initialProps: { actor: brand }, wrapper });
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  let finish!: (value: Awaited<ReturnType<typeof Client.getSkejSchedulingReadiness>>) => void;
  let first = true;
  const readiness = spyOn(Client, "getSkejSchedulingReadiness").mockImplementation(actor => { if (first) { first = false; return new Promise(resolve => { finish = resolve; }); } return Promise.resolve({ accountDid: actor.session.did, connected: true }); });
  const create = spyOn(Client, "createSkejSchedule").mockImplementation(async actor => { actor.assertCurrentActor(); return {} as Client.SkejScheduleSummary; }); restores.push(() => create.mockRestore());
  const previous = result.current;
  let writing!: Promise<unknown>;
  await act(async () => { writing = previous.schedule("Old Actor", "2099-01-01T12:00:00Z").catch(error => error); await Promise.resolve(); });
  rerender({ actor: owner });
  await act(async () => { finish({ accountDid: brand, connected: true }); });
  const failure = await writing;
  expect(failure).toBeInstanceOf(Error);
  expect(create).not.toHaveBeenCalled();
  expect((failure as Error).message).toContain("Account Changed");
  readiness.mockRestore();
});
test("keeps readiness failures separate from an empty calendar and skips reads when disabled", async () => {
  const readiness = spyOn(Client, "getSkejSchedulingReadiness").mockRejectedValue(new Error("Unavailable"));
  const { result, rerender } = renderHook(({ enabled }) => useSkejScheduling(owner, owner, { enabled }), { initialProps: { enabled: false }, wrapper });
  expect(readiness).not.toHaveBeenCalled();
  rerender({ enabled: true });
  await waitFor(() => expect(result.current.readiness.isError).toBe(true));
  expect(result.current.schedules.data).toBeUndefined();
  expect(Client.listSkejSchedules).not.toHaveBeenCalled();
  readiness.mockRestore();
});

test("does not revive a deferred brand restore after A to B to A selection", async () => {
  const { result, rerender } = renderHook(({ actor }) => useSkejScheduling(owner, actor, { includeSchedules: false }), { initialProps: { actor: brand }, wrapper });
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  let finish!: (session: OAuthSession) => void;
  const restore = spyOn(Sessions, "restoreBrandAccount").mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const create = spyOn(Client, "createSkejSchedule").mockResolvedValue({} as Client.SkejScheduleSummary); restores.push(() => create.mockRestore());
  let writing!: Promise<unknown>;
  await act(async () => { writing = result.current.schedule("Old Generation", "2099-01-01T12:00:00Z").catch(error => error); await Promise.resolve(); });
  rerender({ actor: owner });
  rerender({ actor: brand });
  await act(async () => finish(linked));
  const failure = await writing;
  expect(failure).toBeInstanceOf(Error);
  expect((failure as Error).message).toContain("Account Changed");
  expect(create).not.toHaveBeenCalled();
  restore.mockRestore();
});
test("does not revive a deferred readiness write after A to B to A selection", async () => {
  const { result, rerender } = renderHook(({ actor }) => useSkejScheduling(owner, actor, { includeSchedules: false }), { initialProps: { actor: brand }, wrapper });
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  let finish!: (value: Awaited<ReturnType<typeof Client.getSkejSchedulingReadiness>>) => void;
  const readiness = spyOn(Client, "getSkejSchedulingReadiness").mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const create = spyOn(Client, "createSkejSchedule").mockResolvedValue({} as Client.SkejScheduleSummary); restores.push(() => create.mockRestore());
  let writing!: Promise<unknown>;
  await act(async () => { writing = result.current.schedule("Old Readiness", "2099-01-01T12:00:00Z").catch(error => error); await Promise.resolve(); });
  rerender({ actor: owner });
  rerender({ actor: brand });
  await act(async () => finish({ accountDid: brand, connected: true }));
  const failure = await writing;
  expect(failure).toBeInstanceOf(Error);
  expect((failure as Error).message).toContain("Account Changed");
  expect(create).not.toHaveBeenCalled();
  readiness.mockRestore();
});

test("revokes a deferred write synchronously across unlink and relink registry events", async () => {
  const listeners = new Set<() => void>();
  const events = spyOn(Sessions, "onBrandAccountsChanged").mockImplementation(callback => { listeners.add(callback); return () => listeners.delete(callback); }); restores.push(() => events.mockRestore());
  const create = spyOn(Client, "createSkejSchedule").mockResolvedValue({} as Client.SkejScheduleSummary); restores.push(() => create.mockRestore());
  const { result, rerender } = renderHook(() => useSkejScheduling(owner, brand, { includeSchedules: false }), { wrapper });
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  let finish!: (value: Awaited<ReturnType<typeof Client.getSkejSchedulingReadiness>>) => void;
  const readiness = spyOn(Client, "getSkejSchedulingReadiness").mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  let writing!: Promise<unknown>;
  await act(async () => { writing = result.current.schedule("Revoked Draft", "2099-01-01T12:00:00Z").catch(error => error); await Promise.resolve(); });
  expect(listeners.size).toBe(1);
  // Both notifications happen before any render. Membership returns to the same
  // DID, but the token/readiness captured before unlink must remain revoked.
  registered = false; listeners.forEach(notify => notify());
  registered = true; listeners.forEach(notify => notify());
  await act(async () => finish({ accountDid: brand, connected: true }));
  const failure = await writing;
  expect(failure).toBeInstanceOf(Error);
  expect((failure as Error).message).toContain("Account Changed");
  expect(create).not.toHaveBeenCalled();
  rerender();
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  await act(async () => { await result.current.schedule("New Linked Draft", "2099-01-01T12:00:00Z"); });
  expect(create).toHaveBeenCalledTimes(1);
  expect(create.mock.calls[0][1]).toBe("New Linked Draft");
  const revisions = cache.getQueryCache().getAll().filter(query => query.queryKey[0] === "skejScheduling" && query.queryKey.at(-1) === "readiness").map(query => query.queryKey[4]);
  expect(revisions).toContain(0);
  expect(revisions).toContain(2);
  readiness.mockRestore();
});

test("skips scheduling reads, brand restore, and writes for Free viewers", async () => {
  isPro = false;
  const create = spyOn(Client, "createSkejSchedule").mockResolvedValue({} as Client.SkejScheduleSummary); restores.push(() => create.mockRestore());
  const { result } = renderHook(() => useSkejScheduling(owner, brand), { wrapper });
  await act(async () => {});
  expect(Client.getSkejSchedulingReadiness).not.toHaveBeenCalled();
  expect(Client.listSkejSchedules).not.toHaveBeenCalled();
  expect(Sessions.restoreBrandAccount).not.toHaveBeenCalled();
  await act(async () => { await expect(result.current.schedule("Free Draft", "2099-01-01T12:00:00Z")).rejects.toThrow("Requires Social Wire Pro"); });
  expect(create).not.toHaveBeenCalled();
  expect(Sessions.restoreBrandAccount).not.toHaveBeenCalled();
});
test("revokes captured scheduling actor guards and writes after downgrade", async () => {
  const create = spyOn(Client, "createSkejSchedule").mockResolvedValue({} as Client.SkejScheduleSummary); restores.push(() => create.mockRestore());
  const { result, rerender } = renderHook(() => useSkejScheduling(owner, brand, { includeSchedules: false }), { wrapper });
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  const actor = (Client.getSkejSchedulingReadiness as typeof Client.getSkejSchedulingReadiness & { mock: { calls: [Parameters<typeof Client.getSkejSchedulingReadiness>[0]][] } }).mock.calls[0][0];
  expect(() => actor.assertCurrentActor()).not.toThrow();
  isPro = false;
  rerender();
  expect(() => actor.assertCurrentActor()).toThrow();
  await act(async () => { await expect(result.current.schedule("Downgraded Draft", "2099-01-01T12:00:00Z")).rejects.toThrow(); });
  expect(create).not.toHaveBeenCalled();
});

test("prepares an owned article with fresh publication data before submitting to Skej", async () => {
  const pub = { uri: `at://${owner}/site.standard.publication/blog`, cid: "fresh", name: "Blog", url: "https://blog.test", host: "leaflet" as const, record: {} };
  const pubs = spyOn(Publishing, "listArticlePublications").mockResolvedValue([pub]); restores.push(() => pubs.mockRestore());
  const record = { $type: "site.standard.document" as const, title: "Article", site: pub.uri, publishedAt: "2099-01-01T12:00:00.000Z" };
  const prepare = spyOn(Preparation, "prepareScheduledArticle").mockResolvedValue({ record, publishRkey: "3mabc234567ab", title: "Article", url: "https://blog.test/article" }); restores.push(() => prepare.mockRestore());
  const create = spyOn(Client, "createSkejArticleSchedule").mockResolvedValue({} as Client.SkejArticleScheduleSummary); restores.push(() => create.mockRestore());
  const { result } = renderHook(() => useSkejScheduling(owner, owner), { wrapper });
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  await act(async () => { await result.current.scheduleArticle({ publication: { ...pub, cid: "stale" }, title: "Article", markdown: "Content", path: "/article", tags: [] }, record.publishedAt); });
  expect(prepare.mock.calls[0]![0].publication.cid).toBe("fresh");
  expect(create.mock.calls[0]![0].session.did).toBe(owner);
  expect(create.mock.calls[0]![1]).toEqual(record);
});

test("does not submit an article after the account changes during preparation", async () => {
  const pub = { uri: `at://${owner}/site.standard.publication/blog`, cid: "fresh", name: "Blog", url: "https://blog.test", host: "leaflet" as const, record: {} };
  const pubs = spyOn(Publishing, "listArticlePublications").mockResolvedValue([pub]); restores.push(() => pubs.mockRestore());
  let finish!: (value: Awaited<ReturnType<typeof Preparation.prepareScheduledArticle>>) => void;
  const prepare = spyOn(Preparation, "prepareScheduledArticle").mockImplementation(() => new Promise(resolve => { finish = resolve; })); restores.push(() => prepare.mockRestore());
  const create = spyOn(Client, "createSkejArticleSchedule").mockResolvedValue({} as Client.SkejArticleScheduleSummary); restores.push(() => create.mockRestore());
  const { result, rerender } = renderHook(({ actor }) => useSkejScheduling(owner, actor), { wrapper, initialProps: { actor: owner } });
  await waitFor(() => expect(result.current.readiness.data?.connected).toBe(true));
  let pending!: Promise<unknown>;
  await act(async () => { pending = result.current.scheduleArticle({ publication: pub, title: "Article", markdown: "Content", path: "/article", tags: [] }, "2099-01-01T12:00:00Z").catch(error => error); });
  await waitFor(() => expect(prepare).toHaveBeenCalledTimes(1));
  rerender({ actor: brand });
  await act(async () => { finish({ record: { $type: "site.standard.document", title: "Article", site: pub.uri, publishedAt: "2099-01-01T12:00:00Z" }, publishRkey: "3mabc234567ab", title: "Article", url: "https://blog.test/article" }); });
  expect(await pending).toBeInstanceOf(ArticleSchedulingNotSubmittedError);
  expect(create).not.toHaveBeenCalled();
});
