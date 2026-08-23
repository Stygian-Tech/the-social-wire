import { afterEach, beforeAll, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";

import { PublicationTabs } from "@/components/AppSidebar/PublicationTabs";
import { SidebarProvider } from "@/components/ui/sidebar";
import * as BulkReadActions from "@/hooks/useCachedBulkReadActions";

describe("PublicationTabs", () => {
  beforeAll(() => {
    Object.defineProperty(globalThis, "Element", {
      configurable: true,
      value: window.Element,
    });
    Object.defineProperty(globalThis, "HTMLElement", {
      configurable: true,
      value: window.HTMLElement,
    });
    Object.defineProperty(globalThis, "Node", {
      configurable: true,
      value: window.Node,
    });
    Object.defineProperty(globalThis, "DOMRect", {
      configurable: true,
      value: window.DOMRect,
    });
    Object.defineProperty(globalThis, "getComputedStyle", {
      configurable: true,
      value: window.getComputedStyle.bind(window),
    });
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({
        matches: false,
        addEventListener: () => undefined,
        removeEventListener: () => undefined,
      }),
    });
    Object.defineProperty(globalThis, "requestAnimationFrame", {
      configurable: true,
      value: (callback: FrameRequestCallback) =>
        setTimeout(() => callback(performance.now()), 0),
    });
    Object.defineProperty(globalThis, "cancelAnimationFrame", {
      configurable: true,
      value: (id: ReturnType<typeof setTimeout>) => clearTimeout(id),
    });
  });

  afterEach(() => {
    cleanup();
  });

  it("offers only Mark All As Read on top-level feed context menus", async () => {
    const bulkReadSpy = spyOn(
      BulkReadActions,
      "useCachedBulkReadActions",
    ).mockReturnValue({
      cachedEntryIds: [],
      bulkDisabled: false,
      applyMarkAllRead: () => undefined,
      applyMarkAllUnread: () => undefined,
    });

    render(
      <SidebarProvider>
        <PublicationTabs
          activeTab="subscribed"
          onTabChange={() => undefined}
        />
      </SidebarProvider>,
    );

    const subscribed = screen.getByRole("tab", { name: "Subscribed" });
    expect(
      subscribed
        .querySelector("svg")
        ?.classList.contains("lucide-newspaper"),
    ).toBe(true);
    fireEvent.contextMenu(subscribed);

    expect(await screen.findByText("Mark All As Read")).toBeDefined();
    expect(screen.queryByText("Mark All As Unread")).toBeNull();

    bulkReadSpy.mockRestore();
  });

  it("renders The Wire without a bulk-read context menu", () => {
    const onWireSelect = mock(() => undefined);
    render(
      <SidebarProvider>
        <PublicationTabs
          activeTab={null}
          onTabChange={() => undefined}
          wireEnabled
          wireActive
          onWireSelect={onWireSelect}
          visibleTabs={[]}
        />
      </SidebarProvider>,
    );

    const wire = screen.getByRole("tab", { name: "The Wire, Alpha" });
    expect(screen.getByText("Alpha")).toBeDefined();
    expect(wire.querySelector("svg")?.classList.contains("lucide-rss")).toBe(true);
    expect(wire.getAttribute("aria-selected")).toBe("true");
    fireEvent.click(wire);
    expect(onWireSelect).toHaveBeenCalledTimes(1);
    fireEvent.contextMenu(wire);
    expect(screen.queryByText("Mark All As Read")).toBeNull();
  });
});
