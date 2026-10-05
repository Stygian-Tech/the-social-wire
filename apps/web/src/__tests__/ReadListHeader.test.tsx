import { afterEach, beforeAll, describe, expect, it, spyOn } from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as Lists from "@/hooks/useStandardReaderLists";
import * as Mobile from "@/hooks/use-mobile";
import * as Auth from "@/hooks/useAuth";
import { SidebarProvider } from "@/components/ui/sidebar";
import { ReadListHeader } from "@/app/read/ReadListHeader";
beforeAll(() => {
  for (const name of ["HTMLElement", "Element", "Node"] as const)
    Object.defineProperty(globalThis, name, {
      configurable: true,
      value: window[name],
    });
  Object.defineProperty(globalThis, "getComputedStyle", {
    configurable: true,
    value: window.getComputedStyle.bind(window),
  });
});
const restores: (() => void)[] = [];
afterEach(() => {
  cleanup();
  restores
    .splice(0)
    .reverse()
    .forEach((restore) => restore());
});
describe("Standard Reader List route header", () => {
  it("uses resolved list metadata and refreshes only the viewer's list feed without subscribed bulk actions", async () => {
    const uri = "at://did:plc:creator/app.standard-reader.list/tech";
    let metadataRefresh = 0;
    let listsRefresh = 0;
    const client = new QueryClient();
    const calls: unknown[] = [];
    const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false);
    const invalidate = spyOn(client, "invalidateQueries").mockImplementation(
      async (args) => {
        calls.push(args);
      },
    );
    const list = spyOn(Lists, "useStandardReaderList").mockReturnValue({
      data: { name: "Creator's Technology" },
      refetch: async () => {
        metadataRefresh++;
      },
    } as unknown as ReturnType<typeof Lists.useStandardReaderList>);
    const lists = spyOn(Lists, "useStandardReaderLists").mockReturnValue({
      refreshing: false,
      refresh: async () => {
        listsRefresh++;
      },
    } as unknown as ReturnType<typeof Lists.useStandardReaderLists>);
    const auth = spyOn(Auth, "useAuth").mockReturnValue({
      session: { did: "did:plc:viewer" },
    } as unknown as ReturnType<typeof Auth.useAuth>);
    restores.push(
      ...[invalidate, list, lists, auth, mobile].map(
        (spy) => () => spy.mockRestore(),
      ),
    );
    render(
      <QueryClientProvider client={client}>
        <SidebarProvider>
          <ReadListHeader uri={uri} />
        </SidebarProvider>
      </QueryClientProvider>,
    );
    expect(
      screen.getByRole("heading", { name: "Creator's Technology" }),
    ).toBeTruthy();
    expect(screen.queryByRole("button", { name: /Mark All/i })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Refresh List" }));
    await waitFor(() => expect(metadataRefresh).toBe(1));
    expect(listsRefresh).toBe(1);
    expect(calls).toEqual([
      { queryKey: ["aggregateEntries", "did:plc:viewer", "list", uri] },
    ]);
  });
});
