import { afterAll, afterEach, beforeAll, expect, it, mock } from "bun:test";
import { cleanup, render } from "@testing-library/react";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { SidebarProvider } from "@/components/ui/sidebar";

const originalObserver = globalThis.ResizeObserver;
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => {
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
});
afterAll(() => {
  if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
});
afterEach(() => { cleanup(); globalThis.ResizeObserver = originalObserver; });

it("keeps the feed scroll overlay attached through header rerenders", () => {
  const disconnect = mock(() => {});
  const observe = mock(() => {});
  globalThis.ResizeObserver = class {
    observe = observe;
    disconnect = disconnect;
    unobserve = () => {};
  } as unknown as typeof ResizeObserver;
  const shell = (title: string) => <SidebarProvider><main>
    <FeedHeader title={title} />
    <div className="overflow-y-auto" data-testid="feed" />
  </main></SidebarProvider>;
  const view = render(shell("Following"));
  const attachments = observe.mock.calls.length;
  expect(attachments).toBeGreaterThan(0);
  view.getByTestId("feed").scrollTop = 720;
  view.rerender(shell("Updated Following"));
  expect(disconnect).not.toHaveBeenCalled();
  expect(observe).toHaveBeenCalledTimes(attachments);
  expect(view.getByTestId("feed").dataset.floatingGlassScrollTop).toBe("true");
  expect(view.getByTestId("feed").scrollTop).toBe(720);
  const original = view.getByTestId("feed");
  view.rerender(<SidebarProvider><main>
    <FeedHeader title="Another Feed" />
    <div key="another-feed" className="overflow-y-auto" data-testid="feed" />
  </main></SidebarProvider>);
  expect(view.getByTestId("feed")).not.toBe(original);
  expect(view.getByTestId("feed").dataset.floatingGlassScrollTop).toBe("true");
  expect(original.hasAttribute("data-floating-glass-scroll-top")).toBe(false);
  expect(disconnect).toHaveBeenCalledTimes(attachments);
  view.unmount();
  expect(disconnect).toHaveBeenCalledTimes(attachments * 2);
});
