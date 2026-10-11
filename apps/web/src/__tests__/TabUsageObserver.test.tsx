import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { StrictMode } from "react";
import { cleanup, fireEvent, render } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as OAuth from "@/lib/auth";
import * as Telemetry from "@/lib/tabUsageTelemetry";
import { TabUsageObserver } from "@/components/TabUsageObserver";

const restores: (() => void)[] = [];
let owner: string | undefined, oauth: OAuthSession | undefined, path: string, visible: string, at: number;
beforeEach(() => {
  owner = "did:plc:viewer"; oauth = { did: owner } as unknown as OAuthSession; path = "/social/messages"; visible = "visible"; at = 100;
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: owner ? { did: owner } : null, getOAuthSession: () => oauth }) as ReturnType<typeof Auth.useAuth>); restores.push(() => auth.mockRestore());
  const hint = spyOn(OAuth, "getStoredOAuthDid").mockImplementation(() => owner ?? null); restores.push(() => hint.mockRestore());
  const pathname = spyOn(Navigation, "usePathname").mockImplementation(() => path); restores.push(() => pathname.mockRestore());
  const params = spyOn(Navigation, "useSearchParams").mockReturnValue(new URLSearchParams("to=private.handle&token=secret") as ReturnType<typeof Navigation.useSearchParams>); restores.push(() => params.mockRestore());
  const send = spyOn(Telemetry, "recordTabUsage").mockResolvedValue(new Response(null, { status: 202 })); restores.push(() => send.mockRestore());
  const clock = spyOn(performance, "now").mockImplementation(() => at); restores.push(() => clock.mockRestore());
  const visibility = Object.getOwnPropertyDescriptor(document, "visibilityState"); Object.defineProperty(document, "visibilityState", { configurable: true, get: () => visible }); restores.push(() => { if (visibility) Object.defineProperty(document, "visibilityState", visibility); else Reflect.deleteProperty(document, "visibilityState"); });
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
test("records only canonical tab labels and excludes hidden dwell", () => {
  const view = render(<TabUsageObserver />);
  expect(Telemetry.recordTabUsage).toHaveBeenCalledWith(oauth, { event: "tab_open", tab: "messages", durationMs: 0 });
  at += 1000; visible = "hidden"; fireEvent(document, new window.Event("visibilitychange"));
  expect(Telemetry.recordTabUsage).toHaveBeenLastCalledWith(oauth, { event: "tab_dwell", tab: "messages", durationMs: 1000 });
  at += 9000; visible = "visible"; fireEvent(document, new window.Event("visibilitychange"));
  at += 2000; view.unmount();
  expect(Telemetry.recordTabUsage).toHaveBeenLastCalledWith(oauth, { event: "tab_dwell", tab: "messages", durationMs: 2000 });
  expect(JSON.stringify((Telemetry.recordTabUsage as ReturnType<typeof mock>).mock.calls.map(call => call[1]))).not.toContain("private");
});
test("signed-out activity and stale-account dwell are not sent", () => {
  owner = undefined; oauth = undefined;
  const view = render(<TabUsageObserver />); expect(Telemetry.recordTabUsage).not.toHaveBeenCalled();
  owner = "did:plc:viewer"; oauth = { did: owner } as unknown as OAuthSession; view.rerender(<TabUsageObserver />);
  expect(Telemetry.recordTabUsage).toHaveBeenCalledTimes(1);
  oauth = { did: "did:plc:other" } as unknown as OAuthSession; at += 1000; view.unmount(); expect(Telemetry.recordTabUsage).toHaveBeenCalledTimes(1);
});
test("canonicalization never retains handles, identifiers or unknown routes", () => {
  expect(Telemetry.canonicalUsageTab("/read/at%3Aprivate", "unknown-secret")).toBe("subscribed");
  expect(Telemetry.canonicalUsageTab("/read", "sports")).toBe("sports");
  expect(Telemetry.canonicalUsageTab("/social/messages/private-convo")).toBe("messages");
  expect(Telemetry.canonicalUsageTab("/content-calendar")).toBe("content-calendar");
  expect(Telemetry.canonicalUsageTab("/callback")).toBeUndefined();
  expect(Telemetry.canonicalUsageTab("/social/unknown")).toBeUndefined();
});
test("visible clocks bound delayed samples and resume without another open", () => {
  const emit = mock(); const clock = Telemetry.tabUsageClock("home", () => at, emit);
  clock.visible(); clock.visible(); at += 200000; clock.hidden(); clock.flush(); clock.visible();
  expect(emit.mock.calls).toEqual([[{ event: "tab_open", tab: "home", durationMs: 0 }], [{ event: "tab_dwell", tab: "home", durationMs: 60000 }]]);
});
test("Do Not Track excludes all tab activity", () => {
  const descriptor = Object.getOwnPropertyDescriptor(navigator, "doNotTrack");
  Object.defineProperty(navigator, "doNotTrack", { configurable: true, value: "1" });
  restores.push(() => { if (descriptor) Object.defineProperty(navigator, "doNotTrack", descriptor); else Reflect.deleteProperty(navigator, "doNotTrack"); });
  render(<TabUsageObserver />); expect(Telemetry.recordTabUsage).not.toHaveBeenCalled();
});

test("Strict Mode does not count the same initial tab visit twice", () => {
  render(<StrictMode><TabUsageObserver /></StrictMode>);
  expect((Telemetry.recordTabUsage as ReturnType<typeof mock>).mock.calls.filter(call => call[1].event === "tab_open")).toHaveLength(1);
});

test("blocked browser storage never breaks navigation", () => {
  const descriptor = Object.getOwnPropertyDescriptor(window, "localStorage");
  Object.defineProperty(window, "localStorage", { configurable: true, get: () => { throw new Error("Storage unavailable"); } });
  restores.push(() => { if (descriptor) Object.defineProperty(window, "localStorage", descriptor); });
  expect(() => render(<TabUsageObserver />)).not.toThrow();
})
