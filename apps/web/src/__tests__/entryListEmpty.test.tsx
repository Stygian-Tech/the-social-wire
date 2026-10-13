import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { EntryList } from "@/components/EntryList/EntryList";
import * as Entries from "@/hooks/useEntries";
import * as Wire from "@/hooks/useWireFeed";
import * as Refresh from "@/hooks/useProactiveFeedRefresh";
import * as Sidebar from "@/contexts/PublicationSidebarContext";

const restores: (() => void)[] = [];
const fetchNextPage = mock(async () => undefined);
const refetch = mock(async () => undefined);
let query: Record<string, unknown>;

beforeEach(() => {
  fetchNextPage.mockClear();
  refetch.mockClear();
  query = {
    data: { pages: [{ entries: [], cursor: undefined }] },
    isLoading: false, isFetching: false, isError: false,
    hasNextPage: false, isFetchingNextPage: false, isFetchNextPageError: false,
    fetchNextPage, refetch,
  };
  const entries = spyOn(Entries, "useEntries").mockImplementation(() => ({ ...query, scopePending: false }) as unknown as ReturnType<typeof Entries.useEntries>);
  const aggregate = spyOn(Entries, "useAggregateFeedEntries").mockImplementation(() => query as unknown as ReturnType<typeof Entries.useAggregateFeedEntries>);
  const wire = spyOn(Wire, "useWireFeedEntries").mockReturnValue({ catalog: {} } as ReturnType<typeof Wire.useWireFeedEntries>);
  const refresh = spyOn(Refresh, "useProactiveFeedRefresh").mockImplementation(() => {});
  const sidebar = spyOn(Sidebar, "useSidebarProjection").mockReturnValue({ allPublicationRows: [] } as unknown as ReturnType<typeof Sidebar.useSidebarProjection>);
  restores.push(() => entries.mockRestore(), () => aggregate.mockRestore(), () => wire.mockRestore(), () => refresh.mockRestore(), () => sidebar.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).forEach(restore => restore()); });

function feed() {
  return <EntryList aggregateFeed={{ kind: "subscribed" }} selectedEntryId={null}
    onSelectEntry={() => {}} isEntryRead={() => true} readIndicatorsEnabled
    articleFilter="unread" markEntryRead={() => {}} markEntryUnread={() => {}} />;
}

it("shows caught-up content for empty and locally read feeds", () => {
  const view = render(feed());
  expect(screen.getByText("No unread stories. You're all caught up.")).toBeTruthy();
  query.data = { pages: [{ entries: [{ entryId: "read", title: "Read Story", publishedAt: "2026-10-12" }] }] };
  view.rerender(feed());
  expect(screen.getByText("No unread stories. You're all caught up.")).toBeTruthy();
  expect(fetchNextPage).not.toHaveBeenCalled();
});

it("scans empty continuation pages and then shows the empty state", async () => {
  query.hasNextPage = true;
  query.data = { pages: [{ entries: [], cursor: "next" }] };
  const view = render(feed());
  expect(screen.getByRole("status").textContent).toBe("Checking for unread stories…");
  await waitFor(() => expect(fetchNextPage).toHaveBeenCalledTimes(1));
  query.isFetching = true;
  query.isFetchingNextPage = true;
  view.rerender(feed());
  expect(fetchNextPage).toHaveBeenCalledTimes(1);
  query.isFetching = false;
  query.isFetchingNextPage = false;
  query.hasNextPage = false;
  query.data = { pages: [{ entries: [], cursor: "next" }, { entries: [] }] };
  view.rerender(feed());
  expect(screen.getByText("No unread stories. You're all caught up.")).toBeTruthy();
});

it("pauses failed scans and retries by refreshing rather than using the failed cursor", async () => {
  query.hasNextPage = true;
  query.isError = true;
  query.isFetchNextPageError = true;
  query.error = new Error("Cursor expired");
  render(feed());
  expect(screen.getByRole("alert").textContent).toContain("Cursor expired");
  expect(fetchNextPage).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  await waitFor(() => expect(refetch).toHaveBeenCalledTimes(1));
  expect(fetchNextPage).not.toHaveBeenCalled();
});
