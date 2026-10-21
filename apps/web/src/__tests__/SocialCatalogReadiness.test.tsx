import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as Images from "@/hooks/useCachedImageUrl";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { SocialFeeds } from "@/components/Social/SocialFeeds";

const did = "did:plc:alice";
const labeler = "did:plc:ar7c4by46qjdydhdevvrndac";
const uri = (key: string) => `at://did:plc:feeds/app.bsky.feed.generator/${key}`;
const restores: (() => void)[] = [];
let client: QueryClient;
afterEach(() => { cleanup(); client?.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function Controls() {
  const catalog = useBlueskySocialCatalog();
  return <><button onClick={() => { void catalog.refetchSafety(); }}>Refresh Catalog</button>{catalog.data?.metadataError ? <p role="status">{catalog.data.metadataError}</p> : null}<SocialFeeds /></>;
}
function generator(key: string) {
  return { uri: uri(key), cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", did: "did:plc:service", creator: { did: "did:plc:feeds", handle: "feeds.example" }, displayName: `${key} Feed`, avatar: `https://images.example/${key}.png`, indexedAt: "2026-10-09T00:00:00Z" };
}

describe("Social feed navigation readiness", () => {
  it("retains validated names, avatar DOM, and authoritative membership while optional metadata stalls or fails", async () => {
    client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
    let members = ["Stable", "Removed"];
    let changedSafety = false;
    let metadata: (() => Promise<unknown>) | undefined;
    const oauth = { did, fetchHandler: async (path: string) => {
      const method = new URL(path, "https://pds.example").pathname.split("/").at(-1);
      if (method === "app.bsky.actor.getPreferences") return Response.json({ preferences: [
        { $type: "app.bsky.actor.defs#savedFeedsPrefV2", items: members.map(id => ({ id, type: "feed", value: uri(id), pinned: true })) },
        ...(changedSafety ? [{ $type: "app.bsky.actor.defs#adultContentPref", enabled: true }] : []),
      ] });
      if (method === "app.bsky.labeler.getServices") return Response.json({ views: [{ $type: "app.bsky.labeler.defs#labelerViewDetailed", uri: `at://${labeler}/app.bsky.labeler.service/self`, cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku", creator: { did: labeler, handle: "labels.example" }, policies: { labelValues: [] }, indexedAt: "2026-10-09T00:00:00Z" }] });
      if (method === "app.bsky.feed.getFeedGenerators") return Response.json(metadata ? await metadata() : { feeds: members.map(generator) });
      throw new Error(`Unexpected ${method}`);
    } } as unknown as OAuthSession;
    const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did }, getOAuthSession: () => oauth } as ReturnType<typeof Auth.useAuth>);
    const path = spyOn(Navigation, "usePathname").mockReturnValue("/social");
    const search = spyOn(Navigation, "useSearchParams").mockReturnValue(new URLSearchParams() as ReturnType<typeof Navigation.useSearchParams>);
    const router = spyOn(Navigation, "useRouter").mockReturnValue({ push() {} } as unknown as ReturnType<typeof Navigation.useRouter>);
    const image = spyOn(Images, "useCachedImageUrl").mockImplementation(source => ({ objectUrl: source ?? undefined, failed: false }));
    restores.push(() => auth.mockRestore(), () => path.mockRestore(), () => search.mockRestore(), () => router.mockRestore(), () => image.mockRestore());
    render(<QueryClientProvider client={client}><Controls /></QueryClientProvider>);
    const stable = await screen.findByRole("button", { name: "Stable Feed" });
    await screen.findByRole("button", { name: "Removed Feed" });
    const avatar = stable.querySelector("img");
    expect(avatar).not.toBeNull();
    let reject!: (error: Error) => void;
    const pending = new Promise<unknown>((_resolve, fail) => { reject = fail; });
    metadata = () => pending;
    members = ["Stable", "New"];
    fireEvent.click(screen.getByRole("button", { name: "Refresh Catalog" }));
    await screen.findByRole("button", { name: "Saved Feed" });
    expect(screen.queryByRole("button", { name: "Removed Feed" })).toBeNull();
    expect(screen.getByRole("button", { name: "Stable Feed" })).toBe(stable);
    expect(stable.querySelector("img")).toBe(avatar);
    expect(screen.getAllByRole("button", { name: "Saved Feed" })).toHaveLength(1);
    await act(async () => { reject(new Error("Optional navigation metadata offline")); });
    await screen.findByRole("status");
    expect(screen.getByRole("button", { name: "Stable Feed" }).querySelector("img")).toBe(avatar);
    expect(screen.queryByRole("alert")).toBeNull();

    changedSafety = true;
    let finish!: (value: unknown) => void;
    const newMetadata = new Promise<unknown>(resolve => { finish = resolve; });
    metadata = () => newMetadata;
    fireEvent.click(screen.getByRole("button", { name: "Refresh Catalog" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "Stable Feed" })).toBeNull());
    expect(screen.getAllByRole("button", { name: "Saved Feed" })).toHaveLength(2);
    expect(screen.getByRole("navigation", { name: "Social Feeds" }).querySelectorAll("img")).toHaveLength(0);
    await act(async () => { finish({ feeds: members.map(generator) }); });
    await screen.findByRole("button", { name: "Stable Feed" });
    await screen.findByRole("button", { name: "New Feed" });
  });
});
