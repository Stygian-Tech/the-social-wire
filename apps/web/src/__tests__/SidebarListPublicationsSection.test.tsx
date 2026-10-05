import {
  afterAll,
  beforeAll,
  beforeEach,
  afterEach,
  describe,
  expect,
  it,
  mock,
} from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
} from "@testing-library/react";
import { SidebarListPublicationsSection } from "@/components/AppSidebar/SidebarListPublicationsSection";
import type { StandardReaderList } from "@/lib/standardReaderListsClient";
import { SidebarProvider } from "@/components/ui/sidebar";

const globalKeys = [
  "DOMRect",
  "Element",
  "HTMLElement",
  "Node",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const originals = new Map(
  globalKeys.map((key) => [
    key,
    Object.getOwnPropertyDescriptor(globalThis, key),
  ]),
);
const originalMatchMedia = Object.getOwnPropertyDescriptor(
  window,
  "matchMedia",
);
beforeAll(() => {
  const values = {
    DOMRect: window.DOMRect,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(performance.now()), 0),
    cancelAnimationFrame: (handle: ReturnType<typeof setTimeout>) =>
      clearTimeout(handle),
  };
  for (const key of globalKeys)
    Object.defineProperty(globalThis, key, {
      configurable: true,
      writable: true,
      value: values[key],
    });
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: () => ({
      matches: false,
      addEventListener: () => undefined,
      removeEventListener: () => undefined,
    }),
  });
});
afterAll(() => {
  for (const key of globalKeys) {
    const descriptor = originals.get(key);
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else Reflect.deleteProperty(globalThis, key);
  }
  if (originalMatchMedia)
    Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
});

const first = "at://did:plc:alice/site.standard.publication/first";
const second = "https://example.org/feed.xml";
const list: StandardReaderList = {
  uri: "at://did:plc:alice/app.standard-reader.list/test",
  name: "Technology", creatorDid: "did:plc:alice", users: [],
  owned: false, saved: true, publications: [first, second],
  publicationDetails: [
    {publicationId: second, title: "Second Source", authorDid: "did:web:example.org"},
    {publicationId: first, title: "Alice’s Blog", authorDid: "did:plc:alice", authorHandle: "alice.example"},
    {publicationId: "at://extra", title: "Unrelated", authorDid: "did:plc:other"},
  ],
};
function mount(props: Partial<React.ComponentProps<typeof SidebarListPublicationsSection>> = {}) {
  return render(<SidebarProvider><ul><SidebarListPublicationsSection list={list} loading={false} selectedPubId={null} onSelectPub={() => undefined} onRetry={() => undefined} {...props} /></ul></SidebarProvider>);
}
const savedAppEnv = process.env.NEXT_PUBLIC_APP_ENV;
beforeEach(() => { process.env.NEXT_PUBLIC_APP_ENV = "dev"; });
afterEach(() => {
  cleanup();
  if (savedAppEnv === undefined) delete process.env.NEXT_PUBLIC_APP_ENV;
  else process.env.NEXT_PUBLIC_APP_ENV = savedAppEnv;
});
describe("SidebarListPublicationsSection", () => {
  it("preserves exact membership order and opens the exact publication reference", () => {
    const select = mock(() => undefined);
    mount({onSelectPub: select, selectedPubId: first});
    const sources = screen.getAllByRole("button");
    expect(sources.map(source => source.textContent)).toEqual(["?Alice’s Blog@alice.example", "?Second Sourcehttps://example.org/feed.xml"]);
    expect(screen.queryByText("Unrelated")).toBeNull();
    expect(sources[0].hasAttribute("data-active")).toBe(true);
    fireEvent.click(sources[1]);
    expect(select).toHaveBeenCalledWith(second);
    expect(screen.queryByRole("button", {name: /Subscribe|Remove|Add Publication/i})).toBeNull();
  });
  it("keeps unresolved sources visible with their exact reference and navigation", () => {
    const select = mock(() => undefined);
    mount({list: {...list, publicationDetails: []}, onSelectPub: select});
    fireEvent.click(screen.getByRole("button", {name: `Publication: ${first}`}));
    expect(select).toHaveBeenCalledWith(first);
    expect(screen.getByText(second)).toBeTruthy();
  });
  it("distinguishes loading, empty list, and scoped load failures", () => {
    const view = mount({list: undefined, loading: true});
    expect(screen.getByRole("status", {name: "Loading List Publications"})).toBeTruthy();
    expect(screen.queryByText("No Publications In This List.")).toBeNull();
    view.unmount();
    const empty = mount({list: {...list, publications: []}});
    expect(screen.getByText("No Publications In This List.")).toBeTruthy();
    empty.unmount();
    const retry = mock(() => undefined);
    mount({list: undefined, error: "This list is unavailable.", onRetry: retry});
    expect(screen.getByRole("alert").textContent).toContain("This list is unavailable.");
    fireEvent.click(screen.getByRole("button", {name: "Retry"}));
    expect(retry).toHaveBeenCalledTimes(1);
    expect(screen.queryByText("No Publications In This List.")).toBeNull();
  });
  it("retains known members during a failed metadata refresh", () => {
    mount({error: "Refresh failed."});
    expect(screen.getByRole("button", {name: "Alice’s Blog"})).toBeTruthy();
    expect(screen.getByRole("alert")).toBeTruthy();
  });
  it("hides AT references in Production while preserving exact navigation", () => {
    process.env.NEXT_PUBLIC_APP_ENV = "prod";
    const select = mock(() => undefined);
    const view = mount({list: {...list, publicationDetails: []}, onSelectPub: select});
    expect(view.container.innerHTML).not.toContain(first);
    const unresolved = screen.getByRole("button", {name: "Publication"});
    fireEvent.click(unresolved);
    expect(select).toHaveBeenCalledWith(first);
    expect(screen.getByText(second)).toBeTruthy();
  });
  it("retains publication names and public creator handles in Production", () => {
    process.env.NEXT_PUBLIC_APP_ENV = "production";
    const view = mount();
    expect(screen.getByRole("button", {name: "Alice’s Blog"})).toBeTruthy();
    expect(screen.getByText("@alice.example")).toBeTruthy();
    expect(view.container.innerHTML).not.toContain(first);
  });
  it("shows unresolved AT references for Development debugging", () => {
    process.env.NEXT_PUBLIC_APP_ENV = "dev";
    mount({list: {...list, publicationDetails: []}});
    expect(screen.getByText(first)).toBeTruthy();
    expect(screen.getByRole("button", {name: `Publication: ${first}`})).toBeTruthy();
  });

  it.each(["did:plc:alice", "You", "not-a-handle", "bad..example", "bad.123"])("hides the placeholder handle %s in Production", (authorHandle) => {
    process.env.NEXT_PUBLIC_APP_ENV = "prod";
    const select = mock(() => undefined);
    const view = mount({list: {...list, publications: [first], publicationDetails: [{publicationId: first, title: "Alice’s Blog", authorDid: "did:plc:alice", authorHandle}]}, onSelectPub: select});
    expect(view.container.innerHTML).not.toContain(`@${authorHandle}`);
    expect(view.container.innerHTML).not.toContain(first);
    fireEvent.click(screen.getByRole("button", {name: "Alice’s Blog"}));
    expect(select).toHaveBeenCalledWith(first);
  });
  it.each(["did:plc:alice", "You"])("falls back to the Development AT reference for placeholder %s", (authorHandle) => {
    process.env.NEXT_PUBLIC_APP_ENV = "dev";
    mount({list: {...list, publications: [first], publicationDetails: [{publicationId: first, title: "Alice’s Blog", authorDid: "did:plc:alice", authorHandle}]}});
    expect(screen.queryByText(`@${authorHandle}`)).toBeNull();
    expect(screen.getByText(first)).toBeTruthy();
  });

});
