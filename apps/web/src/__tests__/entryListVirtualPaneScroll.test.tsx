import { beforeAll, describe, expect, it } from "bun:test";
import { fireEvent, render } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";

import { EntryListVirtualPane } from "@/components/EntryList/EntryListVirtualPane";
import { AuthProvider } from "@/hooks/useAuth";
import type { EntryListItem } from "@/lib/atprotoClient";
import { clearEntryListScrollOffsetsForTests } from "@/lib/entryListScrollState";

const globalWithResizeObserver = globalThis as typeof globalThis & {
  ResizeObserver?: new (callback: ResizeObserverCallback) => ResizeObserver;
};

if (!globalWithResizeObserver.ResizeObserver) {
  globalWithResizeObserver.ResizeObserver = class ResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
}

beforeAll(() => {
  Object.defineProperty(globalThis, "Element", {
    configurable: true,
    value: window.Element,
  });
  Object.defineProperty(globalThis, "HTMLElement", {
    configurable: true,
    value: window.HTMLElement,
  });
});

function makeEntry(index: number): EntryListItem {
  return {
    entryId: `at://did:plc:alice/site.standard.document/${index}`,
    title: `Entry ${index}`,
    publishedAt: "2026-01-01T00:00:00.000Z",
  };
}

function renderPane(entries: EntryListItem[], scrollStateKey = "test-feed") {
  return (
    <EntryListVirtualPane
      visibleEntries={entries}
      selectedEntryId={null}
      onSelectEntry={() => {}}
      isEntryRead={() => false}
      readIndicatorsEnabled
      hasNextPage={false}
      isFetchingNextPage={false}
      fetchNextPage={() => Promise.resolve()}
      scrollStateKey={scrollStateKey}
      publicationById={new Map()}
      markEntryRead={() => {}}
      markEntryUnread={() => {}}
    />
  );
}

describe("EntryListVirtualPane scroll stability", () => {
  it("preserves scrollTop when visible entries update without remounting", () => {
    const queryClient = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    });
    function Wrapper({ children }: { children: ReactNode }) {
      return (
        <QueryClientProvider client={queryClient}>
          <AuthProvider>{children}</AuthProvider>
        </QueryClientProvider>
      );
    }
    const initialEntries = Array.from({ length: 12 }, (_, index) =>
      makeEntry(index)
    );
    const { container, rerender } = render(renderPane(initialEntries), {
      wrapper: Wrapper,
    });
    const scrollRoot = container.querySelector(
      "[data-entry-list-scroll]"
    ) as HTMLDivElement;

    scrollRoot.scrollTop = 320;
    fireEvent.scroll(scrollRoot);

    rerender(renderPane([makeEntry(100), ...initialEntries]));

    expect(scrollRoot.scrollTop).toBe(320);
  });

  it("restores a feed scroll offset after the pane remounts", () => {
    clearEntryListScrollOffsetsForTests();
    const entries = Array.from({ length: 12 }, (_, index) => makeEntry(index));
    const first = render(renderPane(entries, "subscribed:all"));
    const firstRoot = first.container.querySelector(
      "[data-entry-list-scroll]"
    ) as HTMLDivElement;
    firstRoot.scrollTop = 480;
    fireEvent.scroll(firstRoot);
    first.unmount();

    const second = render(renderPane(entries, "subscribed:all"));
    const restoredRoot = second.container.querySelector(
      "[data-entry-list-scroll]"
    ) as HTMLDivElement;
    expect(restoredRoot.scrollTop).toBe(480);
  });
});
