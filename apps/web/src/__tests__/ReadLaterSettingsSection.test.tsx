import { afterEach, beforeAll, describe, expect, it, spyOn } from "bun:test";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as Auth from "@/hooks/useAuth";
import * as PDS from "@/hooks/usePDSClient";
import * as Preferences from "@/hooks/useReadLaterPreferences";
import * as Collections from "@/hooks/useSembleReadLater";
import * as Semble from "@/lib/semble";
import * as Sync from "@/lib/syncPreferencesClient";
import { ReadLaterSettingsSection } from "@/components/Account/ReadLaterSettingsSection";
const restores: (() => void)[] = [];
beforeAll(() => {
  for (const name of ["HTMLElement", "Element", "Node"] as const)
    Object.defineProperty(globalThis, name, {
      configurable: true,
      value: window[name],
    });
});
afterEach(() => {
  cleanup();
  restores
    .splice(0)
    .reverse()
    .forEach((restore) => restore());
});
function setup(service: "latr-link" | "semble", fail = false) {
  const collection = {
    uri: "at://did:plc:viewer/network.cosmik.collection/read",
    name: "Read",
    cardCount: 2,
  };
  const writes: unknown[] = [];
  const oauth = { did: "did:plc:viewer" };
  const auth = spyOn(Auth, "useAuth").mockReturnValue({
    getOAuthSession: () => oauth,
  } as unknown as ReturnType<typeof Auth.useAuth>);
  const pds = spyOn(PDS, "usePDSClient").mockReturnValue({
    getPreferences: async () => null,
    upsertPreferences: async (value: unknown) => {
      writes.push(value);
      if (fail) throw new Error("Could not save preferences.");
      return { value };
    },
  } as unknown as ReturnType<typeof PDS.usePDSClient>);
  const preferences = spyOn(
    Preferences,
    "useConfiguredReadLaterService",
  ).mockReturnValue({
    serviceId: service,
    sembleConnection:
      service === "semble"
        ? { collectionUri: collection.uri, collectionName: collection.name }
        : undefined,
  } as unknown as ReturnType<typeof Preferences.useConfiguredReadLaterService>);
  const collections = spyOn(
    Collections,
    "useSembleCollections",
  ).mockReturnValue({
    collections: [collection],
    isLoading: false,
    isError: false,
  } as unknown as ReturnType<typeof Collections.useSembleCollections>);
  const scope = spyOn(Semble, "requireSembleScopes").mockResolvedValue(
    undefined,
  );
  const sync = spyOn(Sync, "fetchSyncPreferences").mockResolvedValue(null);
  restores.push(
    ...[auth, pds, preferences, collections, scope, sync].map(
      (spy) => () => spy.mockRestore(),
    ),
  );
  render(
    <QueryClientProvider client={new QueryClient()}>
      <ReadLaterSettingsSection />
    </QueryClientProvider>,
  );
  return { writes, collection };
}
describe("Read Later provider collection disclosure", () => {
  it("hides Semble choices for L@tr and reveals them without changing preferences", () => {
    const { writes } = setup("latr-link");
    expect(
      screen.queryByRole("combobox", { name: "Semble Collection" }),
    ).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Use Semble" }));
    expect(
      screen.getByRole("combobox", { name: "Semble Collection" }),
    ).toBeTruthy();
    expect(writes).toHaveLength(0);
    fireEvent.click(screen.getByRole("button", { name: "Use L@tr.link" }));
    expect(
      screen.queryByRole("combobox", { name: "Semble Collection" }),
    ).toBeNull();
    expect(writes).toHaveLength(0);
  });
  it("commits Semble only after an explicit valid collection selection", async () => {
    const { writes, collection } = setup("latr-link");
    fireEvent.click(screen.getByRole("button", { name: "Use Semble" }));
    fireEvent.change(
      screen.getByRole("combobox", { name: "Semble Collection" }),
      { target: { value: collection.uri } },
    );
    await waitFor(() => expect(writes).toHaveLength(1));
    expect((writes[0] as { readLaterService: string }).readLaterService).toBe(
      "semble",
    );
  });
  it("keeps the configured Semble picker visible and restores it if switching fails", async () => {
    const { writes } = setup("semble", true);
    expect(
      screen.getByRole("combobox", { name: "Semble Collection" }),
    ).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Use L@tr.link" }));
    await waitFor(() => expect(writes).toHaveLength(1));
    await waitFor(() =>
      expect(screen.getByRole("alert").textContent).toContain(
        "Could not save preferences",
      ),
    );
    expect(
      screen.getByRole("combobox", { name: "Semble Collection" }),
    ).toBeTruthy();
  });
});
