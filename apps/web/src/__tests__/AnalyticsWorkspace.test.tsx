import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as Analytics from "@/hooks/useCreatorAnalytics";
import * as Mobile from "@/hooks/use-mobile";
import { SidebarProvider } from "@/components/ui/sidebar";
import AnalyticsPage from "@/app/analytics/page";
import AnalyticsLayout from "@/app/analytics/layout";
import type { AnalyticsSummary } from "@/lib/analytics/creatorAnalyticsClient";

const restores: (() => void)[] = [];
let auth: ReturnType<typeof Auth.useAuth>;
let state: ReturnType<typeof Analytics.useCreatorAnalytics>;
const summary: AnalyticsSummary = { items: [], totals: { engagement: null, tracking: { impressions: 4, views: 2, outboundClicks: 1, ctr: 25 } }, series: [], coverage: { snapshotStart: null, inventoryComplete: false, trackingScope: "social-wire", platformImpressions: null, sampledAt: "2026-10-11T12:00:00Z", engagementKnownItems: 0, totalItems: 1, excludesSelf: true } };
beforeEach(() => {
  auth = { session: { did: "did:plc:alice" }, isLoading: false } as ReturnType<typeof Auth.useAuth>;
  const authSpy = spyOn(Auth, "useAuth").mockImplementation(() => auth); restores.push(() => authSpy.mockRestore());
  const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false); restores.push(() => mobile.mockRestore());
  const media = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
  restores.push(() => { if (media) Object.defineProperty(window, "matchMedia", media); else Reflect.deleteProperty(window, "matchMedia"); });
  state = { summary, items: [], query: { isPending: false, isFetching: false, error: null, hasNextPage: false, refetch: mock(async () => {}), fetchNextPage: mock(async () => {}) }, refresh: { error: null, isPending: false }, collect: mock(async () => {}) } as unknown as ReturnType<typeof Analytics.useCreatorAnalytics>;
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function hook() { const value = spyOn(Analytics, "useCreatorAnalytics").mockImplementation(() => state); restores.push(() => value.mockRestore()); return value; }
async function mount() { const spy = hook(); await act(async () => { render(<SidebarProvider><AnalyticsPage /></SidebarProvider>); }); return spy; }

test("distinguishes unavailable platform counters from period tracking, refreshes and changes range", async () => {
  const spy = await mount();
  expect(screen.getByText(/These Are Not Gains During the Selected Period/)).toBeTruthy();
  expect(screen.getByText(/totals include known counts only/)).toBeTruthy();
  expect(screen.getByText(/Your own activity is excluded/)).toBeTruthy();
  expect(screen.getByText("25.0%")).toBeTruthy();
  expect(screen.getAllByText("—")).toHaveLength(4);
  expect(screen.getByText(/No Content Indexed Yet/)).toBeTruthy();
  fireEvent.change(screen.getByRole("combobox", { name: "Analytics Time Range" }), { target: { value: "7" } });
  expect(spy.mock.calls.at(-1)?.[0]).toBe(7);
  fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(state.collect).toHaveBeenCalledTimes(1));
});
test("opens posts internally, suppresses unsafe article links and pages content", async () => {
  state = { ...state, items: [{ uri: "at://did:plc:alice/app.bsky.feed.post/abc", kind: "post", title: "My Post", url: "https://bsky.app/post", publishedAt: "2026-10-11T12:00:00Z", engagement: { likes: 3, replies: 2, reposts: 1, quotes: 0 }, tracking: summary.totals.tracking, refreshedAt: null }, { uri: "at://did:plc:alice/site.standard.document/abc", kind: "article", title: "Unsafe Article", url: "javascript:alert(1)", publishedAt: "", engagement: null, tracking: summary.totals.tracking, refreshedAt: null }], query: { ...state.query, hasNextPage: true } };
  await mount();
  expect(screen.getByRole("link", { name: "My Post" }).getAttribute("href")).toContain("/social/post?");
  expect(screen.queryByRole("link", { name: "Unsafe Article" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Load More Content" }));
  expect(state.query.fetchNextPage).toHaveBeenCalledTimes(1);
});
test("shows snapshot and tracking start as UTC calendar days", async () => {
  state = { ...state, summary: { ...summary, coverage: { ...summary.coverage, snapshotStart: "2026-10-11", trackingStart: "2026-10-11" } } };
  await mount();
  const day = new Date("2026-10-11T00:00:00Z").toLocaleDateString(undefined, { timeZone: "UTC" });
  expect(screen.getByText(new RegExp(`Snapshot history began ${day.replaceAll("/", "\\/")}`))).toBeTruthy();
  expect(screen.getByText(new RegExp(`Tracking history began ${day.replaceAll("/", "\\/")}`))).toBeTruthy();
});
test("displays loading, recoverable error and retry without fabricating an empty report", async () => {
  state = { ...state, summary: undefined, query: { ...state.query, isPending: true } } as unknown as typeof state; hook();
  const view = render(<SidebarProvider><AnalyticsPage /></SidebarProvider>);
  expect(screen.getByRole("status").textContent).toBe("Loading Analytics…");
  state = { ...state, query: { ...state.query, isPending: false, error: new Error("Provider Unavailable") } } as unknown as typeof state;
  view.rerender(<SidebarProvider><AnalyticsPage /></SidebarProvider>);
  expect(screen.getByRole("alert").textContent).toContain("Provider Unavailable");
  fireEvent.click(screen.getByRole("button", { name: "Retry" })); expect(state.query.refetch).toHaveBeenCalledTimes(1);
  expect(screen.queryByText("Social Wire Activity")).toBeNull();
});
test("the Analytics route waits for authentication and redirects signed-out viewers without rendering private children", async () => {
  const replace = mock<(path: string) => void>(() => {});
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ replace } as unknown as ReturnType<typeof Navigation.useRouter>); restores.push(() => router.mockRestore());
  auth = { ...auth, session: null, isLoading: true };
  const view = render(<AnalyticsLayout><p>Private Analytics</p></AnalyticsLayout>);
  expect(screen.getByRole("status").textContent).toBe("Loading Analytics…"); expect(replace).not.toHaveBeenCalled();
  auth = { ...auth, isLoading: false }; view.rerender(<AnalyticsLayout><p>Private Analytics</p></AnalyticsLayout>);
  await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
  expect(screen.queryByText("Private Analytics")).toBeNull();
  render(<AnalyticsPage />); expect(screen.getByText("Log In to View Analytics.")).toBeTruthy();
});
