import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as Auth from "@/hooks/useAuth";
import * as Preview from "@/lib/latrSaveMetadataBackfill";
import * as Image from "@/hooks/useCachedImageUrl";
import { chatLinkPreviewUrl, SocialChatLinkPreview } from "@/components/Social/SocialChatLinkPreview";

let client: QueryClient;
const restores: (() => void)[] = [];
const did = "did:plc:viewer";
beforeEach(() => {
  client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => ({ did }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
  const image = spyOn(Image, "useCachedImageUrl").mockImplementation(src => ({ objectUrl: src || undefined, failed: false }));
  restores.push(() => auth.mockRestore(), () => image.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function show(text: string) {
  return render(<QueryClientProvider client={client}><SocialChatLinkPreview message={{ text }} /></QueryClientProvider>);
}

describe("chat link previews", () => {
  it("uses UTF-8 facet destinations and selects only one non-post HTTPS link", () => {
    const text = "✨ Read Here https://second.example";
    expect(chatLinkPreviewUrl({ text, facets: [{ index: { byteStart: 4, byteEnd: 13 }, features: [{ $type: "app.bsky.richtext.facet#link", uri: "https://first.example/article" }] }] })).toBe("https://first.example/article");
    expect(chatLinkPreviewUrl({ text: "https://bsky.app/profile/sam.test/post/abc https://example.com/a." })).toBe("https://example.com/a");
    expect(chatLinkPreviewUrl({ text: "http://example.com https://name:secret@example.com" })).toBeUndefined();
  });

  it("deduplicates lookups in the viewer cache and renders safe metadata as text", async () => {
    const fetch = spyOn(Preview, "fetchLatrOgPreview").mockResolvedValue({ title: "<script>no HTML</script>", excerpt: "An article", site: "Example", image: "https://images.example/card.png" });
    restores.push(() => fetch.mockRestore());
    show("https://example.com/article");
    show("https://example.com/article");
    const cards = await screen.findAllByRole("link", { name: "Open <script>no HTML</script>" });
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(fetch.mock.calls[0]?.[0].did).toBe(did);
    expect(fetch.mock.calls[0]?.[1]).toBe("https://example.com/article");
    expect(cards[0].getAttribute("href")).toBe("https://example.com/article");
    expect(document.querySelector("script")).toBeNull();
    expect(document.querySelector("img")?.getAttribute("referrerpolicy")).toBe("no-referrer");
    expect(cards[0].className).toContain("max-w-[400px]");
    const image = document.querySelector("img");
    expect(image?.className).toContain("max-h-60");
    expect(image?.className).toContain("w-auto max-w-full");
    expect(image?.className).not.toContain("object-cover");
  });

  it("omits unsafe images and gracefully omits failed previews", async () => {
    const fetch = spyOn(Preview, "fetchLatrOgPreview").mockResolvedValue({ title: "Safe title", image: "javascript:alert(1)" });
    restores.push(() => fetch.mockRestore());
    const view = show("https://example.com/a");
    await screen.findByRole("link", { name: "Open Safe title" });
    expect(document.querySelector("img")).toBeNull();
    fetch.mockRejectedValue(new Error("Offline"));
    view.rerender(<QueryClientProvider client={client}><SocialChatLinkPreview message={{ text: "https://example.com/b" }} /></QueryClientProvider>);
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
    await act(async () => { await new Promise(resolve => setTimeout(resolve, 10)); });
    expect(screen.queryByRole("link")).toBeNull();
  });

  it("isolates cached metadata between accounts", async () => {
    const fetch = spyOn(Preview, "fetchLatrOgPreview").mockResolvedValue({ title: "First account preview" });
    restores.push(() => fetch.mockRestore());
    const view = show("https://example.com/article");
    await screen.findByRole("link", { name: "Open First account preview" });
    const other = "did:plc:other";
    const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did: other }, getOAuthSession: () => ({ did: other }), oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
    restores.push(() => auth.mockRestore());
    fetch.mockResolvedValue({ title: "Second account preview" });
    view.rerender(<QueryClientProvider client={client}><SocialChatLinkPreview message={{ text: "https://example.com/article" }} /></QueryClientProvider>);
    expect(screen.queryByRole("link", { name: "Open First account preview" })).toBeNull();
    await screen.findByRole("link", { name: "Open Second account preview" });
    expect(fetch.mock.calls[1]?.[0].did).toBe(other);
  });

  it("does not request metadata while signed out or for canonical Bluesky post links", () => {
    const fetch = spyOn(Preview, "fetchLatrOgPreview").mockResolvedValue(null);
    const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: null, getOAuthSession: () => null, oauthSessionReloadSeq: 0 } as unknown as ReturnType<typeof Auth.useAuth>);
    restores.push(() => fetch.mockRestore(), () => auth.mockRestore());
    show("https://example.com");
    show("https://bsky.app/profile/sam.test/post/abc");
    expect(fetch).not.toHaveBeenCalled();
  });
});
