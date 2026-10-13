import { afterEach, expect, mock, spyOn, test } from "bun:test";
import { attachFloatingGlassControlsOverlay, attachFloatingGlassScrollOverlay } from "@/components/shared/floatingGlassScrollOverlay";

const originalObserver = globalThis.ResizeObserver;
afterEach(() => {
  mock.restore();
  globalThis.ResizeObserver = originalObserver;
  document.body.replaceChildren();
});

test("initial geometry is read before overlay writes and unchanged resize avoids invalidation", () => {
  let resized = () => {};
  globalThis.ResizeObserver = class {
    constructor(callback: () => void) { resized = callback; }
    observe = () => {};
    disconnect = () => {};
    unobserve = () => {};
  } as unknown as typeof ResizeObserver;
  const { parent, surface, pane } = fixture("top");
  surface.getBoundingClientRect = () => {
    expect(pane.hasAttribute("data-floating-glass-scroll-top")).toBe(false);
    expect(pane.style.getPropertyValue("--floating-glass-top-content-padding")).toBe("");
    return { height: 64 } as DOMRect;
  };
  const writes = spyOn(parent.style, "setProperty");
  const detach = attachFloatingGlassScrollOverlay(surface, "top");
  expect(writes).toHaveBeenCalledTimes(1);
  surface.getBoundingClientRect = () => ({ height: 64 }) as DOMRect;
  resized();
  expect(writes).toHaveBeenCalledTimes(1);
  detach?.();
});

function fixture(edge: "top" | "bottom") {
  const parent = document.createElement("div");
  const surface = document.createElement("aside");
  const pane = document.createElement("main");
  pane.className = "overflow-y-auto";
  pane.style.paddingTop = "12px";
  pane.style.paddingBottom = "20px";
  surface.style.marginTop = "8px";
  surface.style.marginBottom = "8px";
  parent.append(...(edge === "top" ? [surface, pane] : [pane, surface]));
  document.body.append(parent);
  return { parent, surface, pane };
}

for (const edge of ["top", "bottom"] as const) {
  test(`${edge} overlay follows wrapped surface height and restores previous pane styles`, () => {
    let resized = () => {};
    const disconnect = mock(() => {});
    const observe = mock(() => {});
    globalThis.ResizeObserver = class {
      constructor(callback: () => void) { resized = callback; }
      observe = observe;
      disconnect = disconnect;
      unobserve = () => {};
    } as unknown as typeof ResizeObserver;
    const { parent, surface, pane } = fixture(edge);
    let height = 120;
    surface.getBoundingClientRect = () => ({ height }) as DOMRect;
    const extent = `--floating-glass-${edge}-extent`;
    const padding = `--floating-glass-${edge}-content-padding`;
    const marker = `data-floating-glass-scroll-${edge}`;
    parent.style.setProperty(extent, "old");
    pane.style.setProperty(padding, "previous-padding");
    pane.setAttribute(marker, "previous-marker");
    const detach = attachFloatingGlassScrollOverlay(surface, edge);
    expect(parent.style.getPropertyValue(extent)).toBe("136px");
    expect(pane.style.getPropertyValue(padding)).toBe(edge === "top" ? "12px" : "20px");
    expect(pane.getAttribute(marker)).toBe("true");
    expect(observe).toHaveBeenCalledWith(surface);
    height = 220;
    resized();
    expect(parent.style.getPropertyValue(extent)).toBe("236px");
    detach?.();
    expect(disconnect).toHaveBeenCalledTimes(1);
    expect(parent.style.getPropertyValue(extent)).toBe("old");
    expect(pane.style.getPropertyValue(padding)).toBe("previous-padding");
    expect(pane.getAttribute(marker)).toBe("previous-marker");
  });
}

test("nested reader shells use the top shell marker without padding a non-scrolling wrapper", () => {
  globalThis.ResizeObserver = class {
    observe = () => {};
    disconnect = () => {};
    unobserve = () => {};
  } as unknown as typeof ResizeObserver;
  const { surface, pane, parent } = fixture("top");
  pane.className = "overflow-hidden";
  pane.setAttribute("data-feed-header-shell", "");
  surface.getBoundingClientRect = () => ({ height: 48 }) as DOMRect;
  const detach = attachFloatingGlassScrollOverlay(surface, "top");
  expect(pane.getAttribute("data-floating-glass-shell-top")).toBe("true");
  expect(pane.hasAttribute("data-floating-glass-scroll-top")).toBe(false);
  detach?.();
  expect(parent.style.getPropertyValue("--floating-glass-top-extent")).toBe("");
  expect(pane.hasAttribute("data-floating-glass-shell-top")).toBe(false);
});

test("unsupported adjacent panes and missing ResizeObserver retain their original layout", () => {
  const { surface, pane, parent } = fixture("bottom");
  pane.className = "overflow-hidden";
  expect(attachFloatingGlassScrollOverlay(surface, "bottom")).toBeUndefined();
  pane.className = "overflow-y-auto";
  globalThis.ResizeObserver = undefined as unknown as typeof ResizeObserver;
  expect(attachFloatingGlassScrollOverlay(surface, "bottom")).toBeUndefined();
  expect(parent.style.getPropertyValue("--floating-glass-bottom-extent")).toBe("");
  expect(pane.hasAttribute("data-floating-glass-scroll-bottom")).toBe(false);
});

test("a bottom footer includes mobile navigation clearance in its measured scroll inset", () => {
  globalThis.ResizeObserver = class {
    observe = () => {};
    disconnect = () => {};
    unobserve = () => {};
  } as unknown as typeof ResizeObserver;
  const { surface, parent, pane } = fixture("bottom");
  surface.getBoundingClientRect = () => ({ height: 120 }) as DOMRect;
  surface.style.marginBottom = "88px";
  const detach = attachFloatingGlassScrollOverlay(surface, "bottom");
  expect(parent.style.getPropertyValue("--floating-glass-bottom-extent")).toBe("216px");
  expect(pane.getAttribute("data-floating-glass-scroll-bottom")).toBe("true");
  detach?.();
  expect(parent.style.getPropertyValue("--floating-glass-bottom-extent")).toBe("");
});


test("grouped saved controls resize without replacing the enclosing header extent", () => {
  let resized = () => {};
  const disconnect = mock(() => {});
  globalThis.ResizeObserver = class {
    constructor(callback: () => void) { resized = callback; }
    observe = () => {};
    disconnect = disconnect;
    unobserve = () => {};
  } as unknown as typeof ResizeObserver;
  const { parent, surface } = fixture("top");
  parent.style.setProperty("--floating-glass-top-extent", "64px");
  parent.style.setProperty("--floating-glass-controls-extent", "previous");
  let height = 72;
  surface.getBoundingClientRect = () => ({ height }) as DOMRect;
  const detach = attachFloatingGlassControlsOverlay(surface);
  expect(parent.style.getPropertyValue("--floating-glass-controls-extent")).toBe("72px");
  expect(parent.style.getPropertyValue("--floating-glass-top-extent")).toBe("64px");
  height = 112;
  resized();
  expect(parent.style.getPropertyValue("--floating-glass-controls-extent")).toBe("112px");
  detach?.();
  expect(parent.style.getPropertyValue("--floating-glass-controls-extent")).toBe("previous");
  expect(disconnect).toHaveBeenCalledTimes(1);
});
