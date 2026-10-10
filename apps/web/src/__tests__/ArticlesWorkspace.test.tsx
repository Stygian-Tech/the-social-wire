import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Drafts from "@/hooks/articles/useArticleDrafts";
import * as Publishing from "@/lib/articles/articlePublishingClient";
import type { ArticleDraft } from "@/lib/articles/articleDraftTypes";
import type { ArticlePublication } from "@/lib/articles/articlePublishingTypes";
import { ArticlesWorkspace } from "@/components/Articles/ArticlesWorkspace";
import { SidebarProvider } from "@/components/ui/sidebar";
const did = "did:plc:abcdefghijklmnopqrstuvwx";
const publications: ArticlePublication[] = [
  { uri: `at://${did}/site.standard.publication/one`, cid: "first", name: "First Publication", url: "https://first.test", host: "leaflet", record: {} },
  { uri: `at://${did}/site.standard.publication/two`, cid: "second", name: "Second Publication", url: "https://second.test", host: "offprint", record: {} },
];
let seed: ArticleDraft;
let storageError: string | undefined;
let client: QueryClient;
const persist = mock(async () => {});
const restores: (() => void)[] = [];
const originalRAF = Object.getOwnPropertyDescriptor(globalThis, "requestAnimationFrame");
const originalCancelRAF = Object.getOwnPropertyDescriptor(globalThis, "cancelAnimationFrame");
beforeAll(() => {
  Object.defineProperty(globalThis, "requestAnimationFrame", { configurable: true, value: (callback: FrameRequestCallback) => Number(setTimeout(() => callback(performance.now()), 0)) });
  Object.defineProperty(globalThis, "cancelAnimationFrame", { configurable: true, value: (id: number) => clearTimeout(id) });
});
afterAll(() => {
  if (originalRAF) Object.defineProperty(globalThis, "requestAnimationFrame", originalRAF); else Reflect.deleteProperty(globalThis, "requestAnimationFrame");
  if (originalCancelRAF) Object.defineProperty(globalThis, "cancelAnimationFrame", originalCancelRAF); else Reflect.deleteProperty(globalThis, "cancelAnimationFrame");
});
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => { Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) }); });
afterAll(() => { if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia); else Reflect.deleteProperty(window, "matchMedia"); });
beforeEach(() => {
  seed = { id: "draft", title: "Working Article", markdown: "# Article Body\n\nA private paragraph.", excerpt: "", path: "/working-article", tags: [], publicationUri: publications[0]!.uri, createdAt: "2026-10-10T00:00:00Z", updatedAt: "2026-10-10T00:00:00Z", assets: [], revision: 1 };
  storageError = undefined; persist.mockReset(); persist.mockResolvedValue(undefined);
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did } as unknown as OAuthSession), oauthSessionReloadSeq: 0 } as ReturnType<typeof Auth.useAuth>); restores.push(() => auth.mockRestore());
  const local = spyOn(Drafts, "useArticleDrafts").mockImplementation(() => {
    const [draft, setDraft] = useState(seed);
    return { draft, drafts: [draft], loading: false, status: storageError ? "Not Saved" : "Saved in This Browser", error: storageError, update: patch => setDraft(current => ({ ...current, ...patch })), persist, select: async () => {}, create: async () => draft, remove: async () => {} };
  }); restores.push(() => local.mockRestore());
  const pubs = spyOn(Publishing, "listArticlePublications").mockResolvedValue(publications); restores.push(() => pubs.mockRestore());
  const history = spyOn(Publishing, "listPublishedArticles").mockResolvedValue([]); restores.push(() => history.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
async function show() {
  await act(async () => { render(<QueryClientProvider client={client}><SidebarProvider><ArticlesWorkspace /></SidebarProvider></QueryClientProvider>); });
  await waitFor(() => expect(screen.getByRole("option", { name: "First Publication" })).toBeTruthy());
}
function publishingSpy() {
  const publish = spyOn(Publishing, "publishArticle").mockResolvedValue({ uri: `at://${did}/site.standard.document/published`, cid: "published", url: "https://first.test/working-article" }); restores.push(() => publish.mockRestore());
  return publish;
}
describe("article publishing workspace", () => {
  it("renders the actual block editor and publishes only after explicit confirmation", async () => {
    const publish = publishingSpy();
    await show();
    expect(screen.getByText("A private paragraph.")).toBeTruthy();
    expect(publish).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Publish Article" }));
    expect(await screen.findByRole("dialog")).toBeTruthy();
    expect(publish).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(publish).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Publish Article" }));
    await screen.findByRole("dialog");
    fireEvent.click(screen.getByRole("button", { name: "Publish Now" }));
    await waitFor(() => expect(publish).toHaveBeenCalledTimes(1));
    expect(publish.mock.calls[0]![1]).toMatchObject({ title: seed.title, markdown: seed.markdown, publication: publications[0] });
  });
  it("requires title, content, and a selected owned publication before confirmation", async () => {
    const publish = publishingSpy(); seed.title = ""; seed.publicationUri = "";
    await show();
    expect((screen.getByRole("button", { name: "Publish Article" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByLabelText("Article Title"), { target: { value: "Ready" } });
    expect((screen.getByRole("button", { name: "Publish Article" }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(screen.getByLabelText("Article Publication"), { target: { value: publications[1]!.uri } });
    await waitFor(() => expect((screen.getByRole("button", { name: "Publish Article" }) as HTMLButtonElement).disabled).toBe(false));
    fireEvent.click(screen.getByRole("button", { name: "Markdown" }));
    fireEvent.change(screen.getByLabelText("Article Markdown"), { target: { value: " " } });
    expect((screen.getByRole("button", { name: "Publish Article" }) as HTMLButtonElement).disabled).toBe(true);
    expect(publish).not.toHaveBeenCalled();
  });
  it("passes the chosen publication and relative path through confirmation", async () => {
    const publish = publishingSpy();
    await show();
    fireEvent.change(screen.getByLabelText("Article Publication"), { target: { value: publications[1]!.uri } });
    fireEvent.change(screen.getByLabelText("Article Path"), { target: { value: "/chosen-path" } });
    fireEvent.click(screen.getByRole("button", { name: "Publish Article" }));
    expect(await screen.findByText(/to Second Publication on your public PDS/)).toBeTruthy();
    expect(publish).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Publish Now" }));
    await waitFor(() => expect(publish).toHaveBeenCalledTimes(1));
    expect(publish.mock.calls[0]![1]).toMatchObject({ publication: publications[1], path: "/chosen-path" });
  });
  it("shows storage errors and preserves edits when Save Draft fails", async () => {
    storageError = "Browser Storage Is Full";
    persist.mockRejectedValue(new Error("Browser Storage Is Full"));
    const publish = publishingSpy();
    await show();
    expect(screen.getByRole("alert").textContent).toContain("Browser Storage Is Full");
    fireEvent.click(screen.getByRole("button", { name: "Save Draft" }));
    await waitFor(() => expect(persist).toHaveBeenCalledTimes(1));
    expect((screen.getByLabelText("Article Title") as HTMLInputElement).value).toBe(seed.title);
    fireEvent.click(screen.getByRole("button", { name: "Publish Article" }));
    await screen.findByRole("dialog");
    fireEvent.click(screen.getByRole("button", { name: "Publish Now" }));
    await waitFor(() => expect(persist).toHaveBeenCalledTimes(2));
    expect(publish).not.toHaveBeenCalled();
    expect(screen.getAllByRole("alert").some(alert => alert.textContent?.includes("Browser Storage Is Full"))).toBe(true);
  });
  it("disables publication and article editing for an already published local draft", async () => {
    seed.publishedUri = `at://${did}/site.standard.document/existing`;
    const publish = publishingSpy();
    await show();
    for (const label of ["Article Title", "Article Publication", "Article Path", "Article Excerpt", "Article Tags"]) expect((screen.getByLabelText(label) as HTMLInputElement).disabled).toBe(true);
    expect((screen.getByRole("button", { name: "Publish Article" }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText(/Published article editing will be available/)).toBeTruthy();
    expect(publish).not.toHaveBeenCalled();
  });
});
