import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, waitFor, within } from "@testing-library/react";
import * as auth from "@/hooks/useAuth";
import * as publications from "@/hooks/usePublications";
import * as podcasts from "@/hooks/useImportOpmlPodcasts";
import { OpmlImportSection } from "@/components/Account/OpmlImportSection";
import type { OpmlImportBatchResult } from "@/lib/opmlImport";

const domRestores: (() => void)[] = [];
beforeEach(() => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "HTMLElement");
  Object.defineProperty(globalThis, "HTMLElement", { configurable: true, value: window.HTMLElement });
  domRestores.push(() => { if (previous) Object.defineProperty(globalThis, "HTMLElement", previous); else Reflect.deleteProperty(globalThis, "HTMLElement"); });
});

const restores: (() => void)[] = [];
afterEach(async () => { await act(async () => { cleanup(); await new Promise(resolve => setTimeout(resolve, 0)); }); restores.splice(0).reverse().forEach(restore => restore()); domRestores.splice(0).reverse().forEach(restore => restore()); });
const xml = '<opml><body><outline text="Audio Podcast" xmlUrl="https://example.org/audio?token=secret" /></body></opml>';
const success: OpmlImportBatchResult = { imported: [{ title: "Audio Podcast", feedUrl: "https://example.org/audio?token=secret", sourceIndex: 0, categoryPath: [] }], skippedExisting: [], failed: [] };
function setup() {
  const previous = process.env.NEXT_PUBLIC_PODCASTS_ENABLED;
  process.env.NEXT_PUBLIC_PODCASTS_ENABLED = "true";
  restores.push(() => { if (previous === undefined) delete process.env.NEXT_PUBLIC_PODCASTS_ENABLED; else process.env.NEXT_PUBLIC_PODCASTS_ENABLED = previous; });
  const authSpy = spyOn(auth, "useAuth").mockReturnValue({ session: { did: "did:alice" } } as ReturnType<typeof auth.useAuth>);
  const publicationImport = mock(async () => success);
  const podcastImport = mock(async (input: Parameters<ReturnType<typeof podcasts.useImportOpmlPodcasts>["importer"]["mutateAsync"]>[0]) => { void input; return success; });
  const pub = spyOn(publications, "useImportOpmlFeedSubscriptions").mockReturnValue({ mutateAsync: publicationImport } as unknown as ReturnType<typeof publications.useImportOpmlFeedSubscriptions>);
  const subs = spyOn(publications, "useSkyreaderFeedSubscriptions").mockReturnValue({ data: [], isLoading: false, error: null } as unknown as ReturnType<typeof publications.useSkyreaderFeedSubscriptions>);
  const pod = spyOn(podcasts, "useImportOpmlPodcasts").mockReturnValue({ existing: { data: [], isLoading: false, error: null }, importer: { mutateAsync: podcastImport } } as unknown as ReturnType<typeof podcasts.useImportOpmlPodcasts>);
  restores.push(() => authSpy.mockRestore(), () => pub.mockRestore(), () => subs.mockRestore(), () => pod.mockRestore());
  return { authSpy, publicationImport, podcastImport };
}
async function upload(queries: ReturnType<typeof within>) {
  fireEvent.change(queries.getByLabelText("Choose OPML File"), { target: { files: [new File([xml], "audio.opml")] } });
  await queries.findByLabelText(/Audio Podcast/);
}

it("keeps the destination explicit and resets review when changing private mode", async () => {
  const fixture = setup();
  const view = render(<OpmlImportSection />);
  const queries = within(view.container);
  const destination = queries.getByRole("combobox", { name: "Import To" }) as HTMLSelectElement;
  expect(destination.value).toBe("publications");
  await upload(queries);
  expect(destination.value).toBe("publications");
  expect(queries.queryByLabelText("Private Feeds")).toBeNull();
  fireEvent.change(destination, { target: { value: "podcasts" } });
  expect(queries.queryByLabelText(/Audio Podcast/)).toBeNull();
  await upload(queries);
  fireEvent.click(queries.getByLabelText("Private Feeds"));
  expect(queries.queryByLabelText(/Audio Podcast/)).toBeNull();
  expect(queries.getByText("Saved privately to your account. No public subscription records are created.")).toBeTruthy();
  await upload(queries);
  fireEvent.click(queries.getByRole("button", { name: "Import 1 Feed" }));
  await waitFor(() => expect(fixture.podcastImport).toHaveBeenCalledTimes(1));
  expect(fixture.podcastImport.mock.calls[0]?.[0]).toEqual(expect.objectContaining({ privateFeeds: true, feeds: expect.arrayContaining([expect.objectContaining({ feedUrl: "https://example.org/audio?token=secret" })]) }));
  expect(fixture.publicationImport).not.toHaveBeenCalled();
  expect(await queries.findByText("Your podcasts will appear in Podcasts under Subscribed Shows.")).toBeTruthy();
});

it("resets account-specific file, destination, and pending state on account change", async () => {
  const fixture = setup();
  let resolve: (result: OpmlImportBatchResult) => void = () => {};
  fixture.podcastImport.mockImplementation(() => new Promise(done => { resolve = done; }));
  const view = render(<OpmlImportSection />);
  const queries = within(view.container);
  fireEvent.change(queries.getByRole("combobox"), { target: { value: "podcasts" } });
  fireEvent.click(queries.getByLabelText("Private Feeds"));
  await upload(queries);
  fireEvent.click(queries.getByRole("button", { name: "Import 1 Feed" }));
  await waitFor(() => expect((queries.getByRole("combobox") as HTMLSelectElement).disabled).toBe(true));
  fixture.authSpy.mockReturnValue({ session: { did: "did:bob" } } as ReturnType<typeof auth.useAuth>);
  view.rerender(<OpmlImportSection />);
  expect((queries.getByRole("combobox") as HTMLSelectElement).value).toBe("publications");
  expect((queries.getByRole("combobox") as HTMLSelectElement).disabled).toBe(false);
  expect(queries.queryByText("audio.opml")).toBeNull();
  expect(queries.queryByLabelText("Private Feeds")).toBeNull();
  resolve(success);
  await waitFor(() => expect(queries.queryByText("1 Feed Imported")).toBeNull());
});
