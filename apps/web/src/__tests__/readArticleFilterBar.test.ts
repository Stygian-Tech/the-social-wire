import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { createElement } from "react";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as Navigation from "next/navigation";
import * as ReadRoute from "@/contexts/ReadRouteContext";
import * as ReadScope from "@/contexts/ReadSidebarScopeContext";
import * as Bootstrap from "@/contexts/PublicationSidebarContext";
import * as BulkRead from "@/hooks/useCachedBulkReadActions";
import * as Hydration from "@/hooks/useClientHydrated";
import * as WireEdition from "@/hooks/useWireEdition";
import * as WireFeed from "@/hooks/useWireFeed";
import * as Circle from "@/hooks/useCircleFeed";
import { ReadArticleFilterBar } from "@/app/read/ReadArticleFilterBar";
import { SidebarProvider } from "@/components/ui/sidebar";

const restores: (() => void)[] = [];
let feed = "wire";
const retryWire = mock(async () => undefined);
const retryCircle = mock(async () => undefined);

beforeEach(() => {
  retryWire.mockClear(); retryCircle.mockClear();
  const media = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
  });
  restores.push(() => {
    if (media) Object.defineProperty(window, "matchMedia", media);
    else Reflect.deleteProperty(window, "matchMedia");
  });
  const wireState = { isRefreshingFirstPage: false, isLoading: false, viewerModerationRetryUnavailable: false, retryTheWire: retryWire };
  const spies = [
    spyOn(Navigation, "usePathname").mockReturnValue("/read"),
    spyOn(Navigation, "useSearchParams").mockImplementation(() => new URLSearchParams({ feed }) as unknown as ReturnType<typeof Navigation.useSearchParams>),
    spyOn(ReadRoute, "useReadRoute").mockReturnValue({ articleListFilter: "all" } as unknown as ReturnType<typeof ReadRoute.useReadRoute>),
    spyOn(ReadScope, "useReadSidebarScope").mockReturnValue({ activeFeedScope: { publications: [], displayName: "" } } as unknown as ReturnType<typeof ReadScope.useReadSidebarScope>),
    spyOn(Bootstrap, "useSidebarBootstrap").mockReturnValue({ refresh: { mutate: mock(() => undefined) } } as unknown as ReturnType<typeof Bootstrap.useSidebarBootstrap>),
    spyOn(BulkRead, "useCachedBulkReadActions").mockReturnValue({ bulkDisabled: true, applyMarkAllRead: mock(() => undefined) } as unknown as ReturnType<typeof BulkRead.useCachedBulkReadActions>),
    spyOn(Hydration, "useClientHydrated").mockReturnValue(true),
    spyOn(WireEdition, "useWireEdition").mockReturnValue(wireState as unknown as ReturnType<typeof WireEdition.useWireEdition>),
    spyOn(WireFeed, "useWireFeedEntries").mockReturnValue(wireState as unknown as ReturnType<typeof WireFeed.useWireFeedEntries>),
    spyOn(Circle, "useCircleEdition").mockReturnValue({ isLoading: false, isRefetching: false, refetch: retryCircle, catalog: { isFetching: false, isError: false, data: { enabled: true, available: true } } } as unknown as ReturnType<typeof Circle.useCircleEdition>),
  ];
  restores.push(...spies.map(spy => () => spy.mockRestore()));
});

afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

describe("read feed header", () => {
  it.each([["finance", "Finance"], ["sports", "Sports"]])("provides the shared route header for %s without unrelated reader actions", (routeFeed, title) => {
    feed = routeFeed;
    const { container } = render(createElement(SidebarProvider, null, createElement(ReadArticleFilterBar)));
    const heading = screen.getByRole("heading", { name: title, level: 1 });
    expect(heading.closest("header")).toBe(container.querySelector("header"));
    expect(screen.getByRole("button", { name: "Toggle Sidebar" })).toBeDefined();
    expect(screen.queryByRole("button", { name: /Refresh The Wire|Refresh Your Circle/ })).toBeNull();
    expect(screen.queryByRole("button", { name: /Mark All/ })).toBeNull();
    expect(retryWire).not.toHaveBeenCalled();
    expect(retryCircle).not.toHaveBeenCalled();
  });
  it.each([["wire", "The Wire"], ["circle", "Your Circle"]])("centers the %s header with shared symmetric padding and preserves refresh", (routeFeed, title) => {
    feed = routeFeed;
    const { container } = render(createElement(SidebarProvider, null, createElement(ReadArticleFilterBar)));
    expect(screen.getByRole("heading", { name: `${title}, Beta` })).toBeDefined();
    const header = container.querySelector("header")!;
    expect(header.classList.contains("items-center")).toBe(true);
    expect(header.classList.contains("py-1")).toBe(true);
    expect(header.classList.contains("pt-3")).toBe(false);
    expect(header.querySelector("p")).toBeNull();
    expect(screen.queryByText("Important stories across the social web")).toBeNull();
    expect(screen.queryByText("Showing fallback results")).toBeNull();
    expect(screen.queryByText(/moderation settings/i)).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: `Refresh ${title}` }));
    expect(routeFeed === "circle" ? retryCircle : retryWire).toHaveBeenCalledTimes(1);
  });
});
