import { afterEach, beforeAll, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as auth from "@/hooks/useAuth";
import * as publications from "@/hooks/usePublications";
import * as podcasts from "@/hooks/useImportOpmlPodcasts";
import { OpmlImportSection } from "@/components/Account/OpmlImportSection";
import type { OpmlImportBatchResult } from "@/lib/opmlImport";

beforeAll(() => { Object.defineProperty(globalThis, "HTMLElement", { configurable: true, value: window.HTMLElement }); });

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
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
async function upload() {
  fireEvent.change(screen.getByLabelText("Choose OPML File"), { target: { files: [new File([xml], "audio.opml")] } });
  await screen.findByRole("checkbox", { name: /Audio Podcast/ });
}

it("keeps the destination explicit and resets review when changing private mode", async () => {
  const fixture = setup();
  render(<OpmlImportSection />);
  const destination = screen.getByRole("combobox", { name: "Import To" }) as HTMLSelectElement;
  expect(destination.value).toBe("publications");
  await upload();
  expect(destination.value).toBe("publications");
  expect(screen.queryByRole("checkbox", { name: "Private Feeds" })).toBeNull();
  fireEvent.change(destination, { target: { value: "podcasts" } });
  expect(screen.queryByRole("checkbox", { name: /Audio Podcast/ })).toBeNull();
  await upload();
  fireEvent.click(screen.getByRole("checkbox", { name: "Private Feeds" }));
  expect(screen.queryByRole("checkbox", { name: /Audio Podcast/ })).toBeNull();
  expect(screen.getByText("Saved privately to your account. No public subscription records are created.")).toBeTruthy();
  await upload();
  fireEvent.click(screen.getByRole("button", { name: "Import 1 Feed" }));
  await waitFor(() => expect(fixture.podcastImport).toHaveBeenCalledTimes(1));
  expect(fixture.podcastImport.mock.calls[0]?.[0]).toEqual(expect.objectContaining({ privateFeeds: true, feeds: expect.arrayContaining([expect.objectContaining({ feedUrl: "https://example.org/audio?token=secret" })]) }));
  expect(fixture.publicationImport).not.toHaveBeenCalled();
  expect(await screen.findByText("Your podcasts will appear in Podcasts under Subscribed Shows.")).toBeTruthy();
});

it("resets account-specific file, destination, and pending state on account change", async () => {
  const fixture = setup();
  let resolve: (result: OpmlImportBatchResult) => void = () => {};
  fixture.podcastImport.mockImplementation(() => new Promise(done => { resolve = done; }));
  const view = render(<OpmlImportSection />);
  fireEvent.change(screen.getByRole("combobox"), { target: { value: "podcasts" } });
  fireEvent.click(screen.getByRole("checkbox", { name: "Private Feeds" }));
  await upload();
  fireEvent.click(screen.getByRole("button", { name: "Import 1 Feed" }));
  await waitFor(() => expect((screen.getByRole("combobox") as HTMLSelectElement).disabled).toBe(true));
  fixture.authSpy.mockReturnValue({ session: { did: "did:bob" } } as ReturnType<typeof auth.useAuth>);
  view.rerender(<OpmlImportSection />);
  expect((screen.getByRole("combobox") as HTMLSelectElement).value).toBe("publications");
  expect((screen.getByRole("combobox") as HTMLSelectElement).disabled).toBe(false);
  expect(screen.queryByText("audio.opml")).toBeNull();
  expect(screen.queryByRole("checkbox", { name: "Private Feeds" })).toBeNull();
  resolve(success);
  await waitFor(() => expect(screen.queryByText("1 Feed Imported")).toBeNull());
});
