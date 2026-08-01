import { describe, expect, it } from "bun:test";
import { fireEvent, render } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";

import { EntryListVirtualPane } from "@/components/EntryList/EntryListVirtualPane";
import { AuthProvider } from "@/hooks/useAuth";
import type { EntryListItem } from "@/lib/atprotoClient";

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

function makeEntry(index: number): EntryListItem {
  return {
    entryId: `at://did:plc:alice/site.standard.document/${index}`,
    title: `Entry ${index}`,
    publishedAt: "2026-01-01T00:00:00.000Z",
  };
}

function renderPane(entries: EntryListItem[]) {
  return (
    <EntryListVirtualPane
      visibleEntries={entries}
      selectedEntryId={null}
      onSelectEntry={() => {}}
      isEntryRead={() => false}
      readIndicatorsEnabled
      hasNextPage={false}
      isFetchingNextPage={false}
      fetchNextPage={() => {}}
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
});
