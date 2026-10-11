import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as API from "@/lib/analytics/creatorAnalyticsClient";
import { useCreatorAnalytics } from "@/hooks/useCreatorAnalytics";

const summary = (): API.AnalyticsSummary => ({ items: [], totals: { engagement: null, tracking: { impressions: 0, views: 0, outboundClicks: 0, ctr: null } }, series: [], coverage: { snapshotStart: null, inventoryComplete: true, trackingScope: "social-wire", platformImpressions: null } });
let viewer: string; let oauth: string; let client: QueryClient;
const restores: (() => void)[] = [];
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
beforeEach(() => {
  viewer = "did:plc:alice"; oauth = viewer;
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, getOAuthSession: () => ({ did: oauth } as OAuthSession), oauthSessionReloadSeq: 0 } as ReturnType<typeof Auth.useAuth>)); restores.push(() => auth.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).forEach(restore => restore()); });
describe("creator analytics query isolation", () => {
  it("passes days/cursors/signals and stops repeated cursors", async () => {
    const api = spyOn(API, "getCreatorAnalytics").mockResolvedValue({ ...summary(), cursor: "same" }); restores.push(() => api.mockRestore());
    const { result } = renderHook(() => useCreatorAnalytics(7), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.query.hasNextPage).toBe(true));
    await act(async () => { await result.current.query.fetchNextPage(); });
    await waitFor(() => expect(result.current.query.hasNextPage).toBe(false));
    expect(api.mock.calls[1]![1]).toMatchObject({ days: 7, cursor: "same" });
    expect(api.mock.calls[0]![1].signal).toBeInstanceOf(AbortSignal);
  });
  it("does not display prior account or period data", async () => {
    const api = spyOn(API, "getCreatorAnalytics").mockImplementation(async (session, options) => session.did === "did:plc:alice" && options.days === 7 ? { ...summary(), cursor: "alice" } : new Promise(() => {})); restores.push(() => api.mockRestore());
    const { result, rerender } = renderHook(({ days }) => useCreatorAnalytics(days), { initialProps: { days: 7 }, wrapper: Wrapper });
    await waitFor(() => expect(result.current.summary?.cursor).toBe("alice"));
    rerender({ days: 30 }); expect(result.current.summary).toBeUndefined();
    viewer = "did:plc:bob"; oauth = viewer;
    rerender({ days: 7 }); expect(result.current.summary).toBeUndefined();
  });
  it("rejects a late refresh after account changes without invalidating the new account", async () => {
    let resolve!: (value: API.AnalyticsSummary) => void;
    const api = spyOn(API, "getCreatorAnalytics").mockImplementation(async (_session, options) => options.refresh ? new Promise(done => { resolve = done; }) : summary()); restores.push(() => api.mockRestore());
    const { result, rerender } = renderHook(() => useCreatorAnalytics(30), { wrapper: Wrapper });
    await waitFor(() => expect(result.current.summary).toBeDefined());
    let pending!: Promise<void>;
    act(() => { pending = result.current.collect(); });
    await waitFor(() => expect(resolve).toBeDefined());
    viewer = "did:plc:bob"; oauth = viewer; rerender();
    await act(async () => { resolve(summary()); await expect(pending).rejects.toThrow("account changed"); });
    expect(client.getQueryState(["creatorAnalytics", viewer, 0, 30])?.isInvalidated).toBe(false);
  });
});
