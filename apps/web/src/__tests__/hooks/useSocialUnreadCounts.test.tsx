import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Network from "@/lib/atprotoNetwork";
import * as Chat from "@/lib/blueskyChatClient";
import * as Discovery from "@/lib/blueskySocialDiscoveryClient";
import { useSocialUnreadCounts } from "@/hooks/useSocialUnreadCounts";
let viewer: string | undefined;
let oauth: string | undefined;
let client: QueryClient;
const restores: (() => void)[] = [];
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
beforeEach(() => {
  viewer = "did:plc:alice"; oauth = viewer;
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: viewer ? { did: viewer } : null, getOAuthSession: () => oauth ? { did: oauth } as OAuthSession : null, oauthSessionReloadSeq: 2 } as ReturnType<typeof Auth.useAuth>)); restores.push(() => auth.mockRestore());
  const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://appview.test", plcDirectory: "https://plc.test", handleResolver: "https://appview.test", appViewDid: "did:web:appview.test", chatServiceDid: "did:web:chat.test" }); restores.push(() => network.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).forEach(restore => restore()); });
describe("social sidebar unread counts", () => {
  it("shares notification cache, polls both counts, and refreshes under chat mutation invalidation", async () => {
    const notifications = spyOn(Discovery, "getSocialNotificationUnread").mockResolvedValue(12); restores.push(() => notifications.mockRestore());
    let count = 7;
    const messages = spyOn(Chat, "getBlueskyMessageUnread").mockImplementation(async () => count); restores.push(() => messages.mockRestore());
    const { result } = renderHook(useSocialUnreadCounts, { wrapper: Wrapper });
    await waitFor(() => expect(result.current).toEqual({ notificationCount: 12, messageCount: 7 }));
    expect(client.getQueryData<number>(["blueskySocial", viewer, "notificationUnread", 2])).toBe(12);
    count = 0;
    await act(async () => { await client.invalidateQueries({ queryKey: ["blueskySocial", viewer, "messages"] }); });
    await waitFor(() => expect(result.current.messageCount).toBe(0));
    expect(messages.mock.calls[0]![0].signal).toBeInstanceOf(AbortSignal);
  });
  it("never displays previous account counts or stale failed counts", async () => {
    const notifications = spyOn(Discovery, "getSocialNotificationUnread").mockResolvedValue(12); restores.push(() => notifications.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessageUnread").mockResolvedValue(7); restores.push(() => messages.mockRestore());
    const { result, rerender } = renderHook(useSocialUnreadCounts, { wrapper: Wrapper });
    await waitFor(() => expect(result.current.messageCount).toBe(7));
    oauth = "did:plc:bob";
    await act(async () => { await client.invalidateQueries({ queryKey: ["blueskySocial", viewer] }); });
    await waitFor(() => expect(result.current).toEqual({ notificationCount: 0, messageCount: 0 }));
    viewer = undefined; oauth = undefined; rerender();
    expect(result.current).toEqual({ notificationCount: 0, messageCount: 0 });
  });
  it("does not call chat when the local network has no chat service", async () => {
    const network = spyOn(Network, "getAtprotoNetwork").mockReturnValue({ publicAppView: "https://appview.test", plcDirectory: "https://plc.test", handleResolver: "https://appview.test", appViewDid: "did:web:appview.test" }); restores.push(() => network.mockRestore());
    const notifications = spyOn(Discovery, "getSocialNotificationUnread").mockResolvedValue(1); restores.push(() => notifications.mockRestore());
    const messages = spyOn(Chat, "getBlueskyMessageUnread"); restores.push(() => messages.mockRestore());
    const { result } = renderHook(useSocialUnreadCounts, { wrapper: Wrapper });
    await waitFor(() => expect(result.current.notificationCount).toBe(1));
    expect(result.current.messageCount).toBe(0);
    expect(messages).not.toHaveBeenCalled();
  });
});
