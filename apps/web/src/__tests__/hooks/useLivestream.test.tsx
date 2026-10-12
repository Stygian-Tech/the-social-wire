import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Client from "@/lib/livestream/streamplaceClient";
import { useLivestream } from "@/hooks/useLivestream";
import type { Livestream } from "@/lib/livestream/livestreamTypes";
const stream: Livestream = { uri: "at://did:plc:alice/place.stream.livestream/3mf6w2zabcd22", cid: "cid", record: { $type: "place.stream.livestream", title: "Live", createdAt: "2026-10-11T12:00:00Z", tags: [] } };
const restores: (() => void)[] = [];
let viewer: string;
let cache: QueryClient;
class Socket {
  static instances: Socket[] = [];
  onopen?: () => void; onmessage?: (event: { data: string }) => void; onclose?: () => void; onerror?: () => void; closed = false;
  constructor(readonly url: URL) { Socket.instances.push(this); }
  close() { this.closed = true; }
}
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={cache}>{children}</QueryClientProvider>; }
beforeEach(() => {
  viewer = "did:plc:alice"; Socket.instances = [];
  cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const prior = Object.getOwnPropertyDescriptor(globalThis, "WebSocket"); Object.defineProperty(globalThis, "WebSocket", { configurable: true, value: Socket }); restores.push(() => { if (prior) Object.defineProperty(globalThis, "WebSocket", prior); else Reflect.deleteProperty(globalThis, "WebSocket"); });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, getOAuthSession: () => ({ did: viewer } as unknown as OAuthSession) }) as ReturnType<typeof Auth.useAuth>);
  const list = spyOn(Client, "listLivestreams").mockResolvedValue([]), ingests = spyOn(Client, "getStreamIngests").mockResolvedValue([{ type: "rtmps", url: "rtmps://rtmp.stream.place/live" }]);
  restores.push(() => auth.mockRestore(), () => list.mockRestore(), () => ingests.mockRestore());
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
async function mount() { const hook = renderHook(({ node }) => useLivestream(node), { wrapper: Wrapper, initialProps: { node: "https://stream.place" } }); await waitFor(() => expect(hook.result.current.loading).toBe(false)); return hook; }
test("stable announcement retries retain record identity and never cache private keys", async () => {
  let fail = true;
  const save = spyOn(Client, "saveLivestream").mockImplementation(async () => { if (fail) throw new Error("Lost Response"); return stream; }); restores.push(() => save.mockRestore());
  const { result } = await mount();
  await act(async () => { await expect(result.current.save({ title: "Live", tags: [] })).rejects.toThrow("Lost Response"); });
  fail = false; await act(async () => { await result.current.save({ title: "Live", tags: [] }); });
  expect(save.mock.calls[1]![3].rkey).toBe(save.mock.calls[0]![3].rkey); expect(save.mock.calls[1]![3].createdAt).toBe(save.mock.calls[0]![3].createdAt);
  const generate = spyOn(Client, "generateStreamKey").mockResolvedValue({ secret: "test-private-key", signingKey: "did:key:test", uri: "at://did:plc:alice/place.stream.key/key" }); restores.push(() => generate.mockRestore());
  await act(async () => { await result.current.generateKey(); }); expect(JSON.stringify(cache.getQueryCache().getAll().map(query => query.state.data)).includes("test-private-key")).toBe(false);
});
test("changing nodes closes old socket and discards its data", async () => {
  const { result, rerender } = await mount(); const first = Socket.instances[0]!;
  act(() => { first.onopen?.(); first.onmessage?.({ data: JSON.stringify({ $type: "place.stream.livestream#viewerCount", count: 7, total: 8 }) }); }); expect(result.current.snapshot.viewers).toBe(7);
  rerender({ node: "https://custom.example.com" }); expect(first.closed).toBe(true); expect(result.current.snapshot.viewers).toBeUndefined();
  act(() => { first.onmessage?.({ data: JSON.stringify({ $type: "place.stream.livestream#viewerCount", count: 99 }) }); }); expect(result.current.snapshot.viewers).toBeUndefined(); expect(String(Socket.instances[1]!.url)).toContain("wss://custom.example.com/");
});
test("account switch prevents a pending mutation from committing", async () => {
  let release!: () => void; const gate = new Promise<void>(resolve => { release = resolve; });
  const save = spyOn(Client, "saveLivestream").mockImplementation(async (_session, _node, _input, operation) => { await gate; operation.assertCurrentAccount?.(); return stream; }); restores.push(() => save.mockRestore());
  const { result, rerender } = await mount(); let outcome!: Promise<unknown>;
  act(() => { outcome = result.current.save({ title: "Live", tags: [] }).catch(error => error); }); await act(async () => { viewer = "did:plc:bob"; rerender({ node: "https://stream.place" }); });
  await waitFor(() => expect(result.current.loading).toBe(false));
  await act(async () => { release(); await outcome; }); expect(await outcome).toBeInstanceOf(Error); expect((await outcome as Error).message).toContain("Account Or Node Changed");
});
