import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as Auth from "@/hooks/useAuth";
import * as Navigation from "next/navigation";
import * as Mobile from "@/hooks/use-mobile";
import * as Accounts from "@/hooks/useBrandAccounts";
import * as Sessions from "@/lib/brandAccounts/brandAccountSessions";
import * as Social from "@/components/BrandAccounts/useBrandAccountSocial";
import * as Discovery from "@/lib/blueskySocialDiscoveryClient";
import * as PublicProfile from "@/lib/brandAccounts/brandAccountPublicProfile";
import { BrandAccountViewer } from "@/components/BrandAccounts/BrandAccountViewer";
import BrandAccountsPage from "@/app/brand-accounts/page";
import BrandAccountsLayout from "@/app/brand-accounts/layout";
import { SidebarProvider } from "@/components/ui/sidebar";
import type { OAuthSession } from "@atproto/oauth-client-browser";

const owner = "did:plc:owner", brand = "did:plc:brand";
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const post = { uri: `at://${brand}/app.bsky.feed.post/post`, cid, author: { did: brand, handle: "brand.test", displayName: "Brand", labels: [] }, record: { $type: "app.bsky.feed.post", text: "Brand Post Content", createdAt: "2026-10-11T12:00:00Z" }, indexedAt: "2026-10-11T12:00:00Z", replyCount: 0, repostCount: 0, likeCount: 0 };
let client: QueryClient;
let state: ReturnType<typeof Social.useBrandAccountSocial>;
const restores: (() => void)[] = [];
beforeEach(() => {
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  for (const [name, value] of Object.entries({ getComputedStyle: window.getComputedStyle.bind(window), HTMLInputElement: window.HTMLInputElement, requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) { const previous = Object.getOwnPropertyDescriptor(globalThis, name); Object.defineProperty(globalThis, name, { configurable: true, value }); restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); }); }
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did: owner }, isLoading: false } as ReturnType<typeof Auth.useAuth>); restores.push(() => auth.mockRestore());
  const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false); restores.push(() => mobile.mockRestore());
  const publicProfile = spyOn(PublicProfile, "getBrandAccountPublicProfile").mockResolvedValue({ did: brand, handle: "brand.test", displayName: "Brand" }); restores.push(() => publicProfile.mockRestore());
  const list = spyOn(Accounts, "useBrandAccounts").mockReturnValue([brand]); restores.push(() => list.mockRestore());
  state = { connection: { session: { did: brand } as unknown as OAuthSession, assertCurrentActor: () => {}, retry: mock(() => {}) }, moderation: { userDid: brand, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } }, profile: { data: { did: brand, handle: "brand.test", displayName: "Brand" } }, catalog: {}, posts: { data: { pages: [{ feed: [{ post }] }] }, isPending: false }, notifications: { data: { pages: [{ notifications: [{ uri: "at://did:plc:customer/app.bsky.feed.post/reply", cid, reason: "reply", isRead: false, indexedAt: "2026-10-11T12:01:00Z", author: { did: "did:plc:customer", handle: "customer.test", labels: [] }, record: { $type: "app.bsky.feed.post", text: "Customer Reply", createdAt: "2026-10-11T12:01:00Z", reply: { parent: { uri: post.uri, cid }, root: { uri: post.uri, cid } } } }], posts: [post, { ...post, uri: "at://did:plc:customer/app.bsky.feed.post/reply", author: { did: "did:plc:customer", handle: "customer.test" }, record: { $type: "app.bsky.feed.post", text: "Customer Reply", createdAt: "2026-10-11T12:01:00Z", reply: { parent: { uri: post.uri, cid }, root: { uri: post.uri, cid } } } }] }] }, isPending: false }, unread: { data: 1 }, thread: {}, mutation: { isPending: false, mutateAsync: mock(async () => {}) }, interactions: {}, refresh: mock(async () => {}) } as unknown as ReturnType<typeof Social.useBrandAccountSocial>;
  const social = spyOn(Social, "useBrandAccountSocial").mockImplementation(() => state); restores.push(() => social.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
async function mount(children = <BrandAccountViewer ownerDid={owner} brandDid={brand} />) { await act(async () => { render(<QueryClientProvider client={client}><SidebarProvider>{children}</SidebarProvider></QueryClientProvider>); }); }

test("shows the selected brand identity, immediate reply context and actor-specific engagement", async () => {
  await mount();
  expect(screen.getByText(/Acting as @brand.test/)).toBeTruthy();
  expect(screen.getByText("Customer Reply")).toBeTruthy(); expect(screen.getByText("Brand Post Content")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Like as Brand Account" }));
  await waitFor(() => expect(state.mutation.mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ kind: "like", post: expect.objectContaining({ uri: "at://did:plc:customer/app.bsky.feed.post/reply" }) })));
  fireEvent.click(screen.getByRole("button", { name: "Mark Notifications Read" }));
  expect(state.mutation.mutateAsync).toHaveBeenCalledWith({ kind: "seen" });
});
test("reply composer names the acting brand and publishes the selected immediate post", async () => {
  await mount(); fireEvent.click(screen.getByRole("button", { name: "Reply as Brand Account" }));
  expect(screen.getByRole("dialog").textContent).toContain("Publishing as @brand.test");
  fireEvent.change(screen.getByRole("textbox", { name: "Brand Post Text" }), { target: { value: "Brand Response" } });
  fireEvent.click(screen.getByRole("button", { name: "Post Reply" }));
  await waitFor(() => expect(state.mutation.mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ kind: "post", text: "Brand Response", parent: expect.objectContaining({ uri: "at://did:plc:customer/app.bsky.feed.post/reply" }) })));
});
test("opens posts inline in the brand workspace and returns with Back", async () => {
  state = { ...state, thread: { data: { thread: { $type: "app.bsky.feed.defs#threadViewPost", post, replies: [] } } } as unknown as typeof state.thread };
  await mount(); fireEvent.click(screen.getByText("Customer Reply"));
  expect(screen.getByText("Post Conversation")).toBeTruthy(); expect(screen.queryByRole("dialog")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Back" }));
  expect(screen.getByText("Customer Reply")).toBeTruthy(); expect(screen.queryByText("Post Conversation")).toBeNull();
});
test("mention suggestions use the brand session and insert its selected handle", async () => {
  const people = spyOn(Discovery, "getSocialExplorePage").mockResolvedValue({ posts: [], actors: [{ did: "did:plc:person", handle: "person.test", displayName: "Person", labels: [] }] }); restores.push(() => people.mockRestore());
  await mount(); fireEvent.click(screen.getByRole("button", { name: "Compose Post" }));
  const input = screen.getByRole("textbox", { name: "Brand Post Text" });
  fireEvent.change(input, { target: { value: "Hello @person", selectionStart: 13 } });
  const option = await screen.findByRole("option", { name: "@person.test" });
  expect(people).toHaveBeenCalledWith(expect.objectContaining({ session: state.connection.session, moderation: expect.objectContaining({ userDid: brand }), kind: "people", query: "person" }));
  fireEvent.click(option); expect((input as HTMLTextAreaElement).value).toBe("Hello @person.test ");
});
test("callback failures give a recovery action without rendering untrusted URL messages", async () => {
  const params = spyOn(Navigation, "useSearchParams").mockReturnValue(new URLSearchParams("error=callback_failed&message=untrusted-payload") as unknown as ReturnType<typeof Navigation.useSearchParams>); restores.push(() => params.mockRestore());
  await mount(<BrandAccountsPage />);
  expect(screen.getByRole("alert").textContent).toContain("Brand Account Authorization Failed");
  expect(screen.queryByText(/untrusted-payload/)).toBeNull();
  expect(screen.getByRole("button", { name: "Link Account" })).toBeTruthy();
});
test("unlinks only after confirmation and removes the actor viewer before revocation", async () => {
  const unlink = spyOn(Sessions, "unlinkBrandAccount").mockImplementation(async () => { expect(screen.queryByText(/Acting as @brand.test/)).toBeNull(); }); restores.push(() => unlink.mockRestore());
  await mount(<BrandAccountsPage />);
  fireEvent.click(screen.getByRole("button", { name: new RegExp(`Select Brand Account:.*${brand}`) })); expect(screen.getByText(/Acting as @brand.test/)).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Unlink Account" })); expect(unlink).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Confirm Unlink" }));
  await waitFor(() => expect(unlink).toHaveBeenCalledWith(owner, brand));
});
test("does not expose the brand route to a signed-out owner", async () => {
  spyOn(Auth, "useAuth").mockReturnValue({ session: null, isLoading: false } as ReturnType<typeof Auth.useAuth>);
  const replace = mock<(path: string) => void>(() => {}); const router = spyOn(Navigation, "useRouter").mockReturnValue({ replace } as unknown as ReturnType<typeof Navigation.useRouter>); restores.push(() => router.mockRestore());
  render(<BrandAccountsLayout><BrandAccountsPage /></BrandAccountsLayout>);
  await waitFor(() => expect(replace).toHaveBeenCalledWith("/login"));
  expect(screen.queryByText("Brand Accounts")).toBeNull();
});
