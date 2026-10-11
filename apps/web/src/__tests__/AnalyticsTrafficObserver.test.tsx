import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, render, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Tracking from "@/lib/analyticsTracking";
import * as Gateway from "@/lib/socialWireGatewayClient";
import * as BrandStorage from "@/lib/brandAccounts/brandAccountStorage";
import { AnalyticsTrafficObserver } from "@/components/AnalyticsTrafficObserver";

let did: string | undefined; let oauthDid: string | undefined;
let emit!: (event: Tracking.AnalyticsEvent) => void;
const restores: (() => void)[] = [];
const event: Tracking.AnalyticsEvent = { subjectUri: "at://did:plc:author/app.bsky.feed.post/abc", event: "view", surface: "post-viewer" };
const getOAuthSession = () => oauthDid ? { did: oauthDid } as OAuthSession : null;
beforeEach(() => {
  did = "did:plc:alice"; oauthDid = did;
  Object.defineProperty(navigator, "doNotTrack", { configurable: true, value: "0" });
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: did ? { did } : null, getOAuthSession } as ReturnType<typeof Auth.useAuth>)); restores.push(() => auth.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).forEach(restore => restore()); Reflect.deleteProperty(navigator, "doNotTrack"); });
function setup() {
  const stop = spyOn(Tracking, "observeAnalyticsTraffic").mockImplementation(callback => { emit = callback; return () => {}; }); restores.push(() => stop.mockRestore());
  const fetch = spyOn(Gateway, "gatewayFetch").mockImplementation(async () => new Response(null, { status: 202 })); restores.push(() => fetch.mockRestore());
  return { stop, fetch };
}
it("skips signed-out viewers and Do Not Track", () => {
  const { stop, fetch } = setup();
  did = undefined; const view = render(<AnalyticsTrafficObserver />); expect(stop).not.toHaveBeenCalled();
  did = "did:plc:alice"; Object.defineProperty(navigator, "doNotTrack", { configurable: true, value: "1" });
  view.rerender(<AnalyticsTrafficObserver />); expect(stop).not.toHaveBeenCalled(); expect(fetch).not.toHaveBeenCalled();
});
it("sends only the canonical event fields without destination URLs or message content", async () => {
  const { fetch } = setup(); render(<AnalyticsTrafficObserver />);
  act(() => emit(event));
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  const [session, path, init] = fetch.mock.calls[0]!;
  expect(session.did).toBe("did:plc:alice"); expect(path).toBe("/v1/analytics/events");
  expect(init?.method).toBe("POST"); expect(JSON.parse(init?.body as string)).toEqual(event);
  expect(Object.keys(JSON.parse(init?.body as string)).sort()).toEqual(["event", "subjectUri", "surface"]);
  expect(init?.signal).toBeInstanceOf(AbortSignal);
});
it("excludes a viewer's linked brand content from traffic measurements", async () => {
  const brands = spyOn(BrandStorage, "listBrandAccounts").mockReturnValue(["did:plc:brand"]); restores.push(() => brands.mockRestore());
  const { fetch } = setup(); render(<AnalyticsTrafficObserver />);
  act(() => emit({ ...event, subjectUri: "at://did:plc:brand/app.bsky.feed.post/abc" }));
  await act(async () => {}); expect(fetch).not.toHaveBeenCalled();
  act(() => emit(event)); await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  expect(brands).toHaveBeenCalledWith("did:plc:alice");
});
it("aborts in-flight events and discards queued old-account events on account switch", async () => {
  const { fetch } = setup(); let finish!: (response: Response) => void;
  fetch.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  const view = render(<AnalyticsTrafficObserver />); const oldEmit = emit;
  act(() => { oldEmit(event); oldEmit({ ...event, event: "outbound_click" }); });
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  const signal = fetch.mock.calls[0]![2]?.signal;
  did = "did:plc:bob"; oauthDid = did; view.rerender(<AnalyticsTrafficObserver />);
  expect(signal?.aborted).toBe(true);
  await act(async () => { finish(new Response(null, { status: 202 })); });
  expect(fetch).toHaveBeenCalledTimes(1);
  act(() => oldEmit(event)); await act(async () => {}); expect(fetch).toHaveBeenCalledTimes(1);
});
it("discards a queued event when the OAuth identity mismatches and continues after failures", async () => {
  const { fetch } = setup(); render(<AnalyticsTrafficObserver />);
  oauthDid = "did:plc:other"; act(() => emit(event)); await act(async () => {}); expect(fetch).not.toHaveBeenCalled();
  oauthDid = did; fetch.mockRejectedValueOnce(new Error("Network Offline"));
  act(() => { emit(event); emit({ ...event, event: "outbound_click" }); });
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
});
