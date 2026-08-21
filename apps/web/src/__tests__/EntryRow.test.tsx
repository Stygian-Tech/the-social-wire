import { afterEach, beforeAll, describe, expect, it } from "bun:test";
import { cleanup, render } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";

import { AuthProvider } from "@/hooks/useAuth";
import type { EntryListItem } from "@/lib/atprotoClient";

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

afterEach(cleanup);

describe("EntryRow", () => {
  it("attaches the full AT URI as non-visible card metadata", async () => {
    const { EntryRow } = await import("@/components/EntryList/EntryRow");
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
    const entry: EntryListItem = {
      entryId: "at://did:plc:alice/site.standard.document/entry-1",
      title: "Entry",
      publishedAt: "2026-01-01T00:00:00.000Z",
    };

    const { container, queryByText } = render(
      <EntryRow
        entry={entry}
        isSelected={false}
        onSelect={() => {}}
        isRead={false}
        readIndicatorsEnabled
        onMarkEntryRead={() => {}}
        onMarkEntryUnread={() => {}}
      />,
      { wrapper: Wrapper }
    );

    expect(container.querySelector("[data-at-uri]")?.getAttribute("data-at-uri"))
      .toBe(entry.entryId);
    expect(queryByText(entry.entryId)).toBeNull();
  });

  it("renders The Wire source, reason, and presentation-safe provenance", async () => {
    const { EntryRow } = await import("@/components/EntryList/EntryRow");
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
    const entry: EntryListItem = {
      entryId: "at://did:plc:alice/site.standard.document/entry-1",
      title: "A Ranked Story",
      publishedAt: "2026-08-20T12:00:00.000Z",
      originalUrl: "https://news.example/story",
      wireItem: {
        itemId: "wire:item:one",
        representativeUri:
          "at://did:plc:alice/site.standard.document/entry-1",
        source: {
          name: "Example News",
          domain: "news.example",
          publication: "Example News",
          author: "A. Writer",
        },
        reasons: ["breaking_story"],
        provenance: ["direct_share"],
        publishedAt: "2026-08-20T12:00:00.000Z",
      },
    };

    const { getByText, getByLabelText, queryByText } = render(
      <EntryRow
        entry={entry}
        isSelected={false}
        onSelect={() => {}}
        isRead={true}
        readIndicatorsEnabled={false}
        onMarkEntryRead={() => {}}
        onMarkEntryUnread={() => {}}
      />,
      { wrapper: Wrapper },
    );

    expect(getByText("Example News")).toBeDefined();
    expect(getByText("news.example")).toBeDefined();
    expect(getByText("A. Writer")).toBeDefined();
    expect(getByLabelText("Why this story is on The Wire")).toBeDefined();
    expect(getByText("Breaking Story")).toBeDefined();
    expect(getByText("Directly Shared")).toBeDefined();
    expect(queryByText("Mark As Unread")).toBeNull();
  });
});
