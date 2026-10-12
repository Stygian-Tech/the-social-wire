import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Client from "@/lib/livePosts/livePostClient";
import * as Atmo from "@/lib/livePosts/atmoEventClient";
import * as Publications from "@/lib/articles/articlePublishingClient";
import { useLivePosts } from "@/hooks/useLivePosts";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";

const event: LiveEvent = { $type: "app.thesocialwire.liveEvent", uri: "at://did:plc:alice/app.thesocialwire.liveEvent/launch", cid: "event", title: "Launch", tags: [], destination: "bluesky", createdAt: "2026-10-11T00:00:00Z", updatedAt: "2026-10-11T00:00:00Z", entries: [] };
const input = { title: "Launch", tags: [], destination: "bluesky" as const };
const restores: (() => void)[] = [];
let viewer: string;
let oauth: string;
let cache: QueryClient;
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={cache}>{children}</QueryClientProvider>; }
function deferred() { let resolve!: () => void; const promise = new Promise<void>(done => { resolve = done; }); return { promise, resolve }; }
beforeEach(() => {
  viewer = oauth = "did:plc:alice";
  cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, getOAuthSession: () => ({ did: oauth } as unknown as OAuthSession) }) as ReturnType<typeof Auth.useAuth>);
  const list = spyOn(Client, "listEvents").mockResolvedValue([event]);
  const get = spyOn(Client, "getEvent").mockResolvedValue(event);
  const pubs = spyOn(Publications, "listArticlePublications").mockResolvedValue([]);
  const atmo = spyOn(Atmo, "listViewerAtmoEvents").mockResolvedValue([]);
  restores.push(() => atmo.mockRestore(), () => auth.mockRestore(), () => list.mockRestore(), () => get.mockRestore(), () => pubs.mockRestore());
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });

async function mount() { const hook = renderHook(useLivePosts, { wrapper: Wrapper }); await waitFor(() => expect(hook.result.current.loading).toBe(false)); return hook; }

test("retains update operation ID and timestamp across failures and renews them for new text", async () => {
  let fail = true;
  const publish = spyOn(Client, "publishLiveUpdate").mockImplementation(async () => { if (fail) throw new Error("Connection Lost"); return event; });
  restores.push(() => publish.mockRestore());
  const { result } = await mount();
  await act(async () => { await expect(result.current.publishUpdate(event.uri, "First")).rejects.toThrow("Connection Lost"); });
  fail = false;
  await act(async () => { await result.current.publishUpdate(event.uri, "First"); });
  const first = publish.mock.calls[0]![3];
  const retry = publish.mock.calls[1]![3];
  expect(first.operationId).toBeTruthy();
  expect(Number.isFinite(Date.parse(first.createdAt))).toBe(true);
  expect(retry.operationId).toBe(first.operationId);
  expect(retry.createdAt).toBe(first.createdAt);
  await act(async () => { await result.current.publishUpdate(event.uri, "Second"); });
  expect(publish.mock.calls[2]![3].operationId).not.toBe(first.operationId);
});

test("retains create operation identity for an ambiguous creation retry", async () => {
  let fail = true;
  const create = spyOn(Client, "createEvent").mockImplementation(async () => { if (fail) throw new Error("Connection Lost"); return event; });
  restores.push(() => create.mockRestore());
  const { result } = await mount();
  await act(async () => { await expect(result.current.createEvent(input)).rejects.toThrow("Connection Lost"); });
  fail = false;
  await act(async () => { await result.current.createEvent(input); });
  expect(create.mock.calls[1]![2]?.operationId).toBe(create.mock.calls[0]![2]?.operationId);
  expect(create.mock.calls[1]![2]?.createdAt).toBe(create.mock.calls[0]![2]?.createdAt);
});

test("locks concurrent operations until the active write completes", async () => {
  const gate = deferred();
  const create = spyOn(Client, "createEvent").mockImplementation(async () => { await gate.promise; return event; });
  restores.push(() => create.mockRestore());
  const { result } = await mount();
  let running!: Promise<LiveEvent>;
  act(() => { running = result.current.createEvent(input); });
  expect(result.current.pending).toBe(true);
  await expect(result.current.createEvent(input)).rejects.toThrow("Wait For The Current Live Post Operation.");
  expect(create).toHaveBeenCalledTimes(1);
  await act(async () => { gate.resolve(); await running; });
  expect(result.current.pending).toBe(false);
});

test("guards a pending write against an account switch and isolates operation errors", async () => {
  const gate = deferred();
  const create = spyOn(Client, "createEvent").mockImplementation(async (_session, _input, operation) => { await gate.promise; operation?.assertCurrentAccount?.(); return event; });
  restores.push(() => create.mockRestore());
  const { result, rerender } = await mount();
  let outcome!: Promise<unknown>;
  act(() => { outcome = result.current.createEvent(input).catch(error => error); });
  viewer = oauth = "did:plc:bob";
  rerender();
  expect(result.current.pending).toBe(false);
  await waitFor(() => expect(result.current.loading).toBe(false));
  await act(async () => { gate.resolve(); await outcome; });
  const failure = await outcome;
  expect(failure).toBeInstanceOf(Error);
  expect((failure as Error).message).toContain("Sign In Again");
  expect(result.current.error).toBeNull();
});

test("returns a canonical successful write even when the subsequent refresh fails", async () => {
  const create = spyOn(Client, "createEvent").mockResolvedValue(event);
  restores.push(() => create.mockRestore());
  const { result } = await mount();
  const refresh = spyOn(cache, "invalidateQueries").mockRejectedValue(new Error("Refresh Failed"));
  restores.push(() => refresh.mockRestore());
  await act(async () => { expect(await result.current.createEvent(input)).toEqual(event); });
  expect(result.current.error).toBeNull();
  expect(result.current.pending).toBe(false);
  expect(cache.getQueryData<LiveEvent[]>(["livePosts", viewer])).toContainEqual(event);
});

test("keeps RSVP discovery account-scoped while retaining owned events during discovery failure", async () => {
  const hosted = { uri: "at://did:plc:alice/community.lexicon.calendar.event/launch", cid: "event", title: "Hosted Launch", startsAt: "2026-10-12T12:00:00Z", url: "https://atmo.rsvp/event/launch" };
  const list = spyOn(Atmo, "listViewerAtmoEvents").mockResolvedValue([hosted]);
  restores.push(() => list.mockRestore());
  const { result, rerender } = await mount();
  await waitFor(() => expect(result.current.rsvpEvents).toEqual([hosted]));
  expect(list.mock.calls[0]![0].did).toBe("did:plc:alice");
  viewer = oauth = "did:plc:bob";
  list.mockRejectedValue(new Error("RSVP Discovery Failed"));
  await act(async () => { rerender(); });
  expect(result.current.rsvpEvents).toEqual([]);
  await waitFor(() => expect(result.current.rsvpError?.message).toBe("RSVP Discovery Failed"), { timeout: 2500 });
  expect(result.current.events).toEqual([event]);
});
