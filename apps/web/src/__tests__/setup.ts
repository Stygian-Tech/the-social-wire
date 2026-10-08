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

expect.extend(matchers);
