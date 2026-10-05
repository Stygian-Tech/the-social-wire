import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  mock,
  spyOn,
  test,
} from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";

import { PublicationTabs } from "@/components/AppSidebar/PublicationTabs";
import { SidebarTopicsSection } from "@/components/AppSidebar/SidebarTopicsSection";
import { SidebarProvider } from "@/components/ui/sidebar";
import * as BulkReadActions from "@/hooks/useCachedBulkReadActions";

beforeEach(() => {
  spyOn(BulkReadActions, "useCachedBulkReadActions").mockReturnValue({
    cachedEntryIds: [],
    bulkDisabled: false,
    applyMarkAllRead: () => undefined,
    applyMarkAllUnread: () => undefined,
  });
});

afterEach(() => {
  cleanup();
  mock.restore();
});

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

  it("shows all feeds by default and hides only explicitly excluded feeds", () => {
    const { rerender } = render(
      <SidebarProvider>
        <PublicationTabs activeTab={null} onTabChange={() => undefined} />
      </SidebarProvider>,
    );
    expect(screen.getAllByRole("tab")).toHaveLength(4);
    rerender(
      <SidebarProvider>
        <PublicationTabs
          activeTab={null}
          onTabChange={() => undefined}
          visibleFeeds={new Set(["circle", "following"])}
        />
      </SidebarProvider>,
    );
    expect(screen.getAllByRole("tab")).toHaveLength(2);
    expect(
      screen.getByRole("tab", { name: "Your Circle, Beta" }),
    ).toBeDefined();
    expect(screen.queryByRole("tab", { name: "Finance, Beta" })).toBeNull();
    rerender(
      <SidebarProvider>
        <PublicationTabs
          activeTab={null}
          onTabChange={() => undefined}
          visibleFeeds={new Set()}
        />
      </SidebarProvider>,
    );
    expect(screen.queryByRole("tablist")).toBeNull();
  });

  it("offers only Mark All As Read on top-level feed context menus", async () => {
    render(
      <SidebarProvider>
        <PublicationTabs activeTab="subscribed" onTabChange={() => undefined} />
      </SidebarProvider>,
    );

    const subscribed = screen.getByRole("tab", { name: "Subscribed" });
    expect(
      subscribed.querySelector("svg")?.classList.contains("lucide-newspaper"),
    ).toBe(true);
    fireEvent.contextMenu(subscribed);

    expect(await screen.findByText("Mark All As Read")).toBeDefined();
    expect(screen.queryByText("Mark All As Unread")).toBeNull();
  });

  it("renders The Wire without a bulk-read context menu", () => {
    const onWireSelect = mock(() => undefined);
    render(
      <SidebarProvider>
        <PublicationTabs
          activeTab={null}
          onTabChange={() => undefined}
          wireActive
          onWireSelect={onWireSelect}
        />
      </SidebarProvider>,
    );

    const wire = screen.getByRole("tab", { name: "The Wire, Beta" });
    const beta = wire.querySelector("span.ml-auto")!;
    expect(beta.className).toContain("ml-auto");
    expect(wire.querySelector("svg")?.classList.contains("lucide-rss")).toBe(
      true,
    );
    expect(wire.getAttribute("aria-selected")).toBe("true");
    fireEvent.click(wire);
    expect(onWireSelect).toHaveBeenCalledTimes(1);
    fireEvent.contextMenu(wire);
    expect(screen.queryByText("Mark All As Read")).toBeNull();
  });

  it("renders Your Circle as an independent authenticated feed tab", () => {
    const onCircleSelect = mock(() => undefined);
    render(
      <SidebarProvider>
        <PublicationTabs
          activeTab={null}
          onTabChange={() => undefined}
          circleActive
          onCircleSelect={onCircleSelect}
        />
      </SidebarProvider>,
    );

    const circle = screen.getByRole("tab", { name: "Your Circle, Beta" });
    expect(circle.querySelector("span.ml-auto")).not.toBeNull();
    expect(
      circle.querySelector("svg")?.classList.contains("lucide-network"),
    ).toBe(true);
    expect(circle.getAttribute("aria-selected")).toBe("true");
    fireEvent.click(circle);
    expect(onCircleSelect).toHaveBeenCalledTimes(1);
    fireEvent.contextMenu(circle);
    expect(screen.queryByText("Mark All As Read")).toBeNull();
  });
});

test("Finance belongs to Topics with its icon, Beta badge, and selection behavior", () => {
  const onFinanceSelect = mock(() => undefined);
  const { rerender } = render(
    <SidebarProvider>
      <PublicationTabs activeTab={null} onTabChange={() => undefined} />
      <SidebarTopicsSection financeActive onFinanceSelect={onFinanceSelect} />
    </SidebarProvider>,
  );
  const feeds = screen.getByRole("tablist", { name: "Publication Source" });
  const topics = screen.getByRole("tablist", { name: "Topics" });
  const finance = screen.getByRole("tab", { name: "Finance, Beta" });
  expect(feeds.contains(finance)).toBe(false);
  expect(topics.contains(finance)).toBe(true);
  expect(screen.getByText("Topics")).toBeDefined();
  expect(finance.getAttribute("aria-selected")).toBe("true");
  expect(
    finance
      .querySelector("svg")
      ?.classList.contains("lucide-chart-no-axes-combined"),
  ).toBe(true);
  expect(finance.querySelector("span.ml-auto")?.textContent).toBe("Beta");
  fireEvent.click(finance);
  expect(onFinanceSelect).toHaveBeenCalledTimes(1);
  rerender(
    <SidebarProvider>
      <SidebarTopicsSection />
    </SidebarProvider>,
  );
  expect(
    screen
      .getByRole("tab", { name: "Finance, Beta" })
      .getAttribute("aria-selected"),
  ).toBe("false");
});

test("hides empty Topics and Feeds sections independently", () => {
  const { rerender } = render(
    <SidebarProvider>
      <PublicationTabs
        activeTab={null}
        onTabChange={() => undefined}
        visibleFeeds={new Set(["finance"])}
      />
      <SidebarTopicsSection visibleFeeds={new Set(["finance"])} />
    </SidebarProvider>,
  );
  expect(screen.queryByText("Feeds")).toBeNull();
  expect(screen.getByRole("tablist", { name: "Topics" })).toBeDefined();
  rerender(
    <SidebarProvider>
      <PublicationTabs
        activeTab={null}
        onTabChange={() => undefined}
        visibleFeeds={new Set(["subscribed"])}
      />
      <SidebarTopicsSection visibleFeeds={new Set(["subscribed"])} />
    </SidebarProvider>,
  );
  expect(screen.getByText("Feeds")).toBeDefined();
  expect(screen.queryByText("Topics")).toBeNull();
  expect(screen.queryByRole("tab", { name: "Finance, Beta" })).toBeNull();
});

test("keeps every feed destination visible before catalogs load", () => {
  render(
    <SidebarProvider>
      <PublicationTabs activeTab="subscribed" onTabChange={() => undefined} />
      <SidebarTopicsSection />
    </SidebarProvider>,
  );
  for (const name of [
    "The Wire, Beta",
    "Your Circle, Beta",
    "Finance, Beta",
    "Subscribed",
    "Following",
  ]) {
    expect(screen.getByRole("tab", { name })).toBeDefined();
  }
});

test("aligns unread counts with beta badges inside the feed buttons", () => {
  render(
    <SidebarProvider>
      <PublicationTabs
        activeTab="subscribed"
        onTabChange={() => undefined}
        subscribedUnread={653}
        followingUnread={42}
      />
    </SidebarProvider>,
  );
  const subscribed = screen.getByRole("tab", { name: /^Subscribed/ });
  const count = screen.getByLabelText("653 unread");
  const beta = screen
    .getByRole("tab", { name: "The Wire, Beta" })
    .querySelector("span.ml-auto")!;
  expect(subscribed.contains(count)).toBe(true);
  expect(count.className).toContain("ml-auto");
  expect(count.className).not.toContain("absolute");
  expect(beta.className).toContain("ml-auto");
});
