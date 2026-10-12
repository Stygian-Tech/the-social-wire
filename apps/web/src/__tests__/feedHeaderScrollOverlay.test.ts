import { afterEach, expect, mock, test } from "bun:test";
import { attachFeedHeaderScrollOverlay } from "@/components/FeedHeader/feedHeaderScrollOverlay";

const originalObserver = globalThis.ResizeObserver;
afterEach(() => {
  globalThis.ResizeObserver = originalObserver;
  document.body.replaceChildren();
});

function fixture(scrollable = true) {
  const parent = document.createElement("div");
  const header = document.createElement("header");
  const pane = document.createElement("div");
  pane.className = scrollable ? "overflow-y-auto" : "overflow-hidden";
  pane.style.paddingTop = "12px";
  header.style.marginTop = "8px";
  header.style.marginBottom = "8px";
  parent.append(header, pane);
  document.body.append(parent);
  return { parent, header, pane };
}

test("measures wrapped header extent and restores scoped styles on detach", () => {
  let resized = () => {};
  const disconnect = mock(() => {});
  const observe = mock(() => {});
  globalThis.ResizeObserver = class {
    constructor(callback: () => void) { resized = callback; }
    observe = observe;
    disconnect = disconnect;
    unobserve = () => {};
  } as unknown as typeof ResizeObserver;
  const { parent, header, pane } = fixture();
  let height = 48;
  header.getBoundingClientRect = () => ({ height }) as DOMRect;
  parent.style.setProperty("--floating-glass-top-extent", "old");
  const detach = attachFeedHeaderScrollOverlay(header);
  expect(parent.style.getPropertyValue("--floating-glass-top-extent")).toBe("64px");
  expect(pane.style.getPropertyValue("--floating-glass-top-content-padding")).toBe("12px");
  expect(pane.dataset.floatingGlassScrollTop).toBe("true");
  expect(observe).toHaveBeenCalledWith(header);
  height = 96;
  resized();
  expect(parent.style.getPropertyValue("--floating-glass-top-extent")).toBe("112px");
  detach?.();
  expect(disconnect).toHaveBeenCalledTimes(1);
  expect(parent.style.getPropertyValue("--floating-glass-top-extent")).toBe("old");
  expect(pane.style.getPropertyValue("--floating-glass-top-content-padding")).toBe("");
  expect(pane.hasAttribute("data-floating-glass-scroll-top")).toBe(false);
});

test("leaves complex panes and browsers without ResizeObserver unchanged", () => {
  const { parent, header, pane } = fixture(false);
  expect(attachFeedHeaderScrollOverlay(header)).toBeUndefined();
  pane.className = "overflow-y-auto";
  globalThis.ResizeObserver = undefined as unknown as typeof ResizeObserver;
  expect(attachFeedHeaderScrollOverlay(header)).toBeUndefined();
  expect(parent.style.getPropertyValue("--floating-glass-top-extent")).toBe("");
  expect(pane.hasAttribute("data-floating-glass-scroll-top")).toBe(false);
});

test("measures a reader shell without adding a non-scrolling padding layer", () => {
  const disconnect = mock(() => {});
  globalThis.ResizeObserver = class {
    observe = () => {};
    disconnect = disconnect;
    unobserve = () => {};
  } as unknown as typeof ResizeObserver;
  const { parent, header, pane } = fixture(false);
  pane.setAttribute("data-feed-header-shell", "");
  const nestedScroller = document.createElement("div");
  nestedScroller.setAttribute("data-entry-list-scroll", "");
  pane.append(nestedScroller);
  header.getBoundingClientRect = () => ({ height: 48 }) as DOMRect;

  const detach = attachFeedHeaderScrollOverlay(header);
  expect(parent.style.getPropertyValue("--floating-glass-top-extent")).toBe("64px");
  expect(pane.hasAttribute("data-floating-glass-scroll-top")).toBe(false);
  expect(nestedScroller.parentElement).toBe(pane);
  detach?.();
  expect(parent.style.getPropertyValue("--floating-glass-top-extent")).toBe("");
  expect(disconnect).toHaveBeenCalledTimes(1);
});
