import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { act } from "@testing-library/react";
import { hydrateRoot, type Root } from "react-dom/client";
import { renderToString } from "react-dom/server";
import { useIsMobile } from "@/hooks/use-mobile";

const restores: (() => void)[] = [];
let root: Root | undefined;
let container: HTMLDivElement | undefined;

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  container?.remove();
  container = undefined;
  restores.splice(0).reverse().forEach((restore) => restore());
});

function ResponsiveLayout() {
  return useIsMobile()
    ? <button>Open Mobile Sidebar</button>
    : <aside>Desktop Sidebar</aside>;
}

function serverMarkup() {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "window")!;
  Reflect.deleteProperty(globalThis, "window");
  try {
    return renderToString(<ResponsiveLayout />);
  } finally {
    Object.defineProperty(globalThis, "window", descriptor);
  }
}

function mockViewport(initialWidth: number) {
  let width = initialWidth;
  const widthDescriptor = Object.getOwnPropertyDescriptor(window, "innerWidth");
  Object.defineProperty(window, "innerWidth", { configurable: true, get: () => width });
  restores.push(() => {
    if (widthDescriptor) Object.defineProperty(window, "innerWidth", widthDescriptor);
    else Reflect.deleteProperty(window, "innerWidth");
  });
  const listeners = new Set<() => void>();
  const mql = {
    get matches() { return width < 768; },
    media: "(max-width: 767px)",
    addEventListener: (_event: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener),
  };
  const descriptor = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => {
      expect(query).toBe(mql.media);
      return mql;
    },
  });
  restores.push(() => {
    if (descriptor) Object.defineProperty(window, "matchMedia", descriptor);
    else Reflect.deleteProperty(window, "matchMedia");
  });
  return {
    listeners,
    resize(nextWidth: number) {
      const previousMatches = mql.matches;
      width = nextWidth;
      if (previousMatches !== mql.matches) listeners.forEach((listener) => listener());
    },
  };
}

describe("responsive layout hydration", () => {
  for (const width of [390, 1212]) {
    it(`hydrates server markup at ${width}px without a mismatch, then follows breakpoint changes`, async () => {
      const viewport = mockViewport(width);
      const errors: unknown[] = [];
      const consoleError = spyOn(console, "error").mockImplementation((...args) => errors.push(args));
      restores.push(() => consoleError.mockRestore());

      container = document.createElement("div");
      container.innerHTML = serverMarkup();
      document.body.append(container);
      expect(container.querySelector("aside")?.textContent).toBe("Desktop Sidebar");

      await act(async () => {
        root = hydrateRoot(container!, <ResponsiveLayout />, {
          onRecoverableError: (error) => errors.push(error),
        });
      });
      expect(container.textContent).toBe(width < 768 ? "Open Mobile Sidebar" : "Desktop Sidebar");
      expect(errors).toEqual([]);

      await act(async () => viewport.resize(767));
      expect(container.querySelector("button")?.textContent).toBe("Open Mobile Sidebar");
      await act(async () => viewport.resize(768));
      expect(container.querySelector("aside")?.textContent).toBe("Desktop Sidebar");
      expect(errors).toEqual([]);

      await act(async () => root?.unmount());
      root = undefined;
      expect(viewport.listeners.size).toBe(0);
    });
  }
});
