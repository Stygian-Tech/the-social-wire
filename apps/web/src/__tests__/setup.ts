import { expect } from "bun:test";
import * as matchers from "@testing-library/jest-dom/matchers";
import { JSDOM } from "jsdom";

if (typeof document === "undefined") {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "http://localhost",
  });

  globalThis.window = dom.window as unknown as Window & typeof globalThis;
  globalThis.document = dom.window.document;
  globalThis.navigator = dom.window.navigator;
}

// Browser components schedule focus/observer cleanup beyond a single test's
// temporary globals. Keep the shared jsdom constructors available throughout.
for (const name of ["HTMLElement", "Element", "Node", "DOMRect", "MutationObserver"] as const) {
  if (typeof globalThis[name] === "undefined") {
    Object.defineProperty(globalThis, name, {
      configurable: true,
      writable: true,
      value: window[name],
    });
  }
}

// jsdom does not implement Web Animations. Base UI inspects active animations
// after rendering scroll areas; the shared DOM has no running animations.
// Keep Base UI's existing no-animation completion path when supplying this stub.
Object.defineProperty(globalThis, "BASE_UI_ANIMATIONS_DISABLED", {
  configurable: true,
  value: true,
});
if (typeof window.Element.prototype.getAnimations !== "function") {
  Object.defineProperty(window.Element.prototype, "getAnimations", {
    configurable: true,
    writable: true,
    value: () => [],
  });
}

expect.extend(matchers);
