import { afterEach, beforeEach, expect, it } from "bun:test";
import { act, cleanup, renderHook } from "@testing-library/react";
import { renderToString } from "react-dom/server";
import { useDesktopPublicationRail } from "@/hooks/useDesktopPublicationRail";
const originalMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
let desktop = false;
const listeners = new Set<() => void>();
beforeEach(() => {
  desktop = false;
  Object.defineProperty(window, "matchMedia", { configurable: true, value: (query: string) => {
    expect(query).toBe("(min-width: 1024px)");
    return { matches: desktop, addEventListener: (_event: string, listener: () => void) => listeners.add(listener), removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener) };
  } });
});
afterEach(() => { cleanup(); listeners.clear(); if (originalMedia) Object.defineProperty(window, "matchMedia", originalMedia); else Reflect.deleteProperty(window, "matchMedia"); });
it("moves the publication rail at the lg breakpoint and unsubscribes on unmount", () => {
  const { result, unmount } = renderHook(() => useDesktopPublicationRail());
  expect(result.current).toBe(false);
  act(() => { desktop = true; listeners.forEach(listener => listener()); });
  expect(result.current).toBe(true);
  act(() => { desktop = false; listeners.forEach(listener => listener()); });
  expect(result.current).toBe(false);
  unmount(); expect(listeners.size).toBe(0);
});
it("uses viewport-independent server markup for hydration", () => {
  desktop = true;
  function Rail() { return <output>{useDesktopPublicationRail() ? "Desktop" : "Inline"}</output>; }
  expect(renderToString(<Rail />)).toContain("Inline");
});
