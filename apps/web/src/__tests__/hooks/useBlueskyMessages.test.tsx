import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Network from "@/lib/atprotoNetwork";
import * as Chat from "@/lib/blueskyChatClient";
import { useBlueskyMessages } from "@/hooks/useBlueskyMessages";
let viewer: string;
let oauth: string;
let client: QueryClient;
const restores: (() => void)[] = [];
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
beforeEach(() => {
  viewer = "did:plc:alice"; oauth = viewer;
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, getOAuthSession: () => ({ did: oauth } as OAuthSession), oauthSessionReloadSeq: 0 } as ReturnType<typeof Auth.useAuth>)); restores.push(() => auth.mockRestore());
  const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://appview.test", plcDirectory: "https://plc.test", handleResolver: "https://appview.test", appViewDid: "did:web:appview.test", chatServiceDid: "did:web:chat.test" }); restores.push(() => network.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).forEach(restore => restore()); });
describe("chat query isolation", () => {
  it("passes cursors/signals and stops repeated cursors for both lists and message history", async () => {
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [], cursor: "same" }); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockResolvedValue({ messages: [], cursor: "same" }); restores.push(() => messages.mockRestore());
    const { result } = renderHook(() => useBlueskyMessages("c"), { wrapper: Wrapper });
    await waitFor(() => { expect(result.current.conversations.hasNextPage).toBe(true); expect(result.current.messages.hasNextPage).toBe(true); });
    await act(async () => { await result.current.conversations.fetchNextPage(); await result.current.messages.fetchNextPage(); });
    await waitFor(() => { expect(result.current.conversations.hasNextPage).toBe(false); expect(result.current.messages.hasNextPage).toBe(false); });
    expect(messages.mock.calls[1]![0]).toMatchObject({ viewerDid: viewer, convoId: "c", cursor: "same" });
    expect(messages.mock.calls[0]![0].signal).toBeInstanceOf(AbortSignal);
  });
  it("isolates conversation IDs and accounts and never displays another viewer's messages", async () => {
    const list = spyOn(Chat, "getBlueskyConversations").mockResolvedValue({ convos: [] }); restores.push(() => list.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessages").mockImplementation(async args => args.viewerDid === "did:plc:alice" && args.convoId === "one" ? { messages: [], cursor: "alice-history" } : new Promise(() => {})); restores.push(() => messages.mockRestore());
    const { result, rerender } = renderHook(({ id }) => useBlueskyMessages(id), { initialProps: { id: "one" }, wrapper: Wrapper });
    await waitFor(() => expect(result.current.messages.data?.pages[0]?.cursor).toBe("alice-history"));
    rerender({ id: "two" }); expect(result.current.messages.data).toBeUndefined();
    viewer = "did:plc:bob"; oauth = viewer;
    rerender({ id: "one" }); expect(result.current.messages.data).toBeUndefined();
    expect(client.getQueryCache().getAll().every(query => query.queryKey[0] === "blueskySocial" && query.queryKey[2] === "messages")).toBe(true);
  });
});
