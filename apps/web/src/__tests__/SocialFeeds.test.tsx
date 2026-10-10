import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as Navigation from "next/navigation";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import { SocialFeeds } from "@/components/Social/SocialFeeds";
import { SocialFeedsSheet } from "@/components/Social/SocialFeedsSheet";
import { SOCIAL_FOLLOWING_FEED, type SocialFeed } from "@/lib/blueskySocialClient";

const custom: SocialFeed = { kind: "feed", uri: "at://did:plc:alice/app.bsky.feed.generator/news", name: "Long Custom Feed Name", pinned: true };
const list: SocialFeed = { kind: "list", uri: "at://did:plc:alice/app.bsky.graph.list/team", name: "Team", pinned: false };
const push = mock((path: string) => { void path; });
const refetch = mock(async () => undefined);
let pathname: string;
let params: URLSearchParams;
let state: { data?: { feeds: SocialFeed[] }; isPending: boolean; isError: boolean; refetch: typeof refetch };
const restores: (() => void)[] = [];
const browserGlobals = ["requestAnimationFrame", "cancelAnimationFrame", "HTMLElement", "Element", "Node", "getComputedStyle", "MutationObserver"] as const;
const originalGlobals = new Map(browserGlobals.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
beforeAll(() => {
  const values = { requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout, HTMLElement: window.HTMLElement, Element: window.Element, Node: window.Node, getComputedStyle: window.getComputedStyle.bind(window), MutationObserver: window.MutationObserver };
  for (const key of browserGlobals) Object.defineProperty(globalThis, key, { configurable: true, value: values[key] });
});
afterAll(() => {
  for (const key of browserGlobals) {
    const previous = originalGlobals.get(key);
    if (previous) Object.defineProperty(globalThis, key, previous);
    else Reflect.deleteProperty(globalThis, key);
  }
});
beforeEach(() => {
  pathname = "/social";
  params = new URLSearchParams();
  state = { data: { feeds: [SOCIAL_FOLLOWING_FEED, custom, list] }, isPending: false, isError: false, refetch };
  push.mockClear(); refetch.mockClear();
  const path = spyOn(Navigation, "usePathname").mockImplementation(() => pathname);
  restores.push(() => path.mockRestore());
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ push } as unknown as ReturnType<typeof Navigation.useRouter>);
  const search = spyOn(Navigation, "useSearchParams").mockImplementation(() => params as ReturnType<typeof Navigation.useSearchParams>);
  const catalog = spyOn(Catalog, "useBlueskySocialCatalog").mockImplementation(() => state as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>);
  restores.push(() => router.mockRestore(), () => search.mockRestore(), () => catalog.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

describe("Social feed navigation", () => {
  it("withholds cached saved names when moderation catalog refresh fails", () => {
    const view = render(<SocialFeeds />);
    expect(screen.getByRole("button", { name: custom.name })).toBeTruthy();
    state = { ...state, isError: true };
    view.rerender(<SocialFeeds />);
    expect(screen.queryByRole("button", { name: custom.name }) === null).toBe(true);
    expect(screen.queryByRole("button", { name: list.name }) === null).toBe(true);
    expect(screen.getByRole("button", { name: "Following" })).toBeTruthy();
  });

  it("preserves catalog order and navigates independently to custom and list feeds", async () => {
    params.set("list", list.uri);
    const selected = mock(() => undefined);
    await act(async () => { render(<SocialFeeds onSelect={selected} />); });
    expect(screen.getAllByRole("button").map(button => button.textContent)).toEqual(["Following", custom.name, "Team"]);
    expect(screen.getByRole("button", { name: "Team" }).getAttribute("aria-current")).toBe("page");
    expect(screen.getByRole("button", { name: custom.name }).getAttribute("aria-current")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: custom.name }));
    expect(push).toHaveBeenLastCalledWith(`/social?feed=${encodeURIComponent(custom.uri)}`);
    fireEvent.click(screen.getByRole("button", { name: "Team" }));
    expect(push).toHaveBeenLastCalledWith(`/social?list=${encodeURIComponent(list.uri)}`);
    expect(selected).toHaveBeenCalledTimes(2);
  });

  it("highlights custom feeds and does not mark Following selected", async () => {
    params.set("feed", custom.uri);
    render(<SocialFeeds />);
    expect(screen.getByRole("button", { name: custom.name }).getAttribute("aria-current")).toBe("page");
    expect(screen.getByRole("button", { name: "Following" }).getAttribute("aria-current")).toBeNull();
  });

  it("keeps Following usable while saved feeds load or fail and supports retry", async () => {
    state = { data: undefined, isPending: true, isError: false, refetch };
    const view = render(<SocialFeeds />);
    expect(screen.getByRole("status", { name: "Loading Social Feeds" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Following" }).getAttribute("aria-current")).toBe("page");
    state = { data: undefined, isPending: false, isError: true, refetch };
    view.rerender(<SocialFeeds />);
    expect(screen.getByRole("status").textContent).toBe("Couldn’t load saved feeds.");
    fireEvent.click(screen.getByRole("button", { name: "Following" }));
    expect(push).toHaveBeenCalledWith("/social");
    fireEvent.click(screen.getByRole("button", { name: "Retry" }));
    expect(refetch).toHaveBeenCalled();
  });

  it("does not highlight a Home feed while viewing another Social workspace", () => {
    pathname = "/social/bookmarks";
    render(<SocialFeeds />);
    for (const button of screen.getAllByRole("button")) expect(button.getAttribute("aria-current")).toBeNull();
  });

  it("opens a right-side mobile picker and closes it when selecting a feed", async () => {
    render(<SocialFeedsSheet />);
    expect(screen.queryByRole("navigation", { name: "Social Feeds" })).toBeNull();
    await act(async () => { fireEvent.click(screen.getByRole("button", { name: "Choose Social Feed" })); });
    expect(screen.getByRole("dialog").getAttribute("data-side")).toBe("right");
    expect(screen.getByRole("navigation", { name: "Social Feeds" })).toBeTruthy();
    await act(async () => { fireEvent.click(screen.getByRole("button", { name: custom.name })); });
    expect(push).toHaveBeenCalledWith(`/social?feed=${encodeURIComponent(custom.uri)}`);
    expect(screen.queryByRole("dialog")).toBeNull();
  });
});
