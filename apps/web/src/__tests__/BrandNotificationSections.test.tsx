import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Accounts from "@/hooks/useBrandAccounts";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Discovery from "@/hooks/useSocialDiscovery";
import * as Social from "@/components/BrandAccounts/useBrandAccountSocial";
import * as Mobile from "@/hooks/use-mobile";
import { SocialNotifications } from "@/components/Social/SocialNotifications";
import { SidebarProvider } from "@/components/ui/sidebar";
import { includeBrandNotifications, setIncludeBrandNotifications } from "@/lib/brandAccounts/brandNotificationPreferences";

const owner = "did:plc:owner", brand = "did:plc:brand";
const restores: (() => void)[] = [];
let currentOwner: string; let accounts: string[]; let client: QueryClient;
let brandAction: ReturnType<typeof mock>; let personalAction: ReturnType<typeof mock>;
const moderation = (did: string) => ({ userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } });
beforeEach(() => {
  window.localStorage.clear(); currentOwner = owner; accounts = [brand];
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  brandAction = mock(async () => {}); personalAction = mock(() => {});
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: currentOwner } }) as ReturnType<typeof Auth.useAuth>); restores.push(() => auth.mockRestore());
  const linked = spyOn(Accounts, "useBrandAccounts").mockImplementation(() => accounts); restores.push(() => linked.mockRestore());
  const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false); restores.push(() => mobile.mockRestore());
  const catalog = spyOn(Catalog, "useBlueskySocialCatalog").mockImplementation(() => ({ data: { moderation: moderation(currentOwner) } }) as unknown as ReturnType<typeof Catalog.useBlueskySocialCatalog>); restores.push(() => catalog.mockRestore());
  const personal = spyOn(Discovery, "useSocialNotifications").mockReturnValue({ data: { pages: [{ notifications: [], posts: [] }] }, isPending: false } as unknown as ReturnType<typeof Discovery.useSocialNotifications>); restores.push(() => personal.mockRestore());
  const unread = spyOn(Discovery, "useSocialNotificationUnread").mockReturnValue({ data: 2 } as ReturnType<typeof Discovery.useSocialNotificationUnread>); restores.push(() => unread.mockRestore());
  const seen = spyOn(Discovery, "useMarkSocialNotificationsSeen").mockReturnValue({ mutate: personalAction } as unknown as ReturnType<typeof Discovery.useMarkSocialNotificationsSeen>); restores.push(() => seen.mockRestore());
  const social = spyOn(Social, "useBrandAccountSocial").mockImplementation((_owner, did) => ({ connection: { session: { did } as OAuthSession }, moderation: moderation(did), profile: { data: { did, handle: "brand.test" } }, catalog: {}, notifications: { data: { pages: [{ posts: [], notifications: [] }] }, isPending: false }, unread: { data: 3 }, posts: {}, thread: {}, mutation: { mutateAsync: brandAction }, interactions: {}, refresh: () => {} }) as unknown as ReturnType<typeof Social.useBrandAccountSocial>); restores.push(() => social.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function mount() { return render(<QueryClientProvider client={client}><SidebarProvider><SocialNotifications /></SidebarProvider></QueryClientProvider>); }

test("defaults to included brand sections, combines unread and separates mark-read actors", async () => {
  mount();
  const toggle = screen.getByRole("checkbox", { name: "Include Brand Accounts" }) as HTMLInputElement;
  expect(toggle.checked).toBe(true);
  expect(screen.getByRole("region", { name: `Notifications for Brand ${brand}` })).toBeTruthy();
  await waitFor(() => expect(screen.getByText("5 Unread")).toBeTruthy());
  expect(Social.useBrandAccountSocial).toHaveBeenCalledWith(owner, brand, undefined, { includePosts: false });
  expect(screen.queryByRole("button", { name: "Compose Post" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Posts" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Mark Notifications Read" }));
  await waitFor(() => expect(brandAction).toHaveBeenCalledWith({ kind: "seen" }));
  expect(personalAction).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Mark Personal As Read" }));
  expect(personalAction).toHaveBeenCalledTimes(1);
});

test("toggle unmounts brand actors and survives remount only for the personal owner", async () => {
  const view = mount();
  fireEvent.click(screen.getByRole("checkbox", { name: "Include Brand Accounts" }));
  expect(screen.queryByText(/Acting as/)).toBeNull();
  await waitFor(() => expect(screen.getByText("2 Unread")).toBeTruthy());
  expect(includeBrandNotifications(owner)).toBe(false);
  view.unmount(); mount();
  expect((screen.getByRole("checkbox", { name: "Include Brand Accounts" }) as HTMLInputElement).checked).toBe(false);
  expect(includeBrandNotifications("did:plc:other-owner")).toBe(true);
});

test("unlink and personal account switches remove the old brand section immediately", () => {
  const view = mount();
  accounts = []; view.rerender(<QueryClientProvider client={client}><SidebarProvider><SocialNotifications /></SidebarProvider></QueryClientProvider>);
  expect(screen.queryByText(/Acting as/)).toBeNull();
  expect(screen.queryByRole("checkbox", { name: "Include Brand Accounts" })).toBeNull();
  accounts = [brand]; setIncludeBrandNotifications(owner, false); currentOwner = "did:plc:other-owner";
  view.rerender(<QueryClientProvider client={client}><SidebarProvider><SocialNotifications /></SidebarProvider></QueryClientProvider>);
  expect((screen.getByRole("checkbox", { name: "Include Brand Accounts" }) as HTMLInputElement).checked).toBe(true);
  expect(Social.useBrandAccountSocial).toHaveBeenLastCalledWith(currentOwner, brand, undefined, { includePosts: false });
});
test("personal unread errors do not masquerade as a fully known combined total", async () => {
  spyOn(Discovery, "useSocialNotificationUnread").mockReturnValue({ data: 2, isError: true, error: new Error("Personal Count Unavailable") } as ReturnType<typeof Discovery.useSocialNotificationUnread>);
  mount();
  expect(screen.getByText("Unread Counts Unavailable")).toBeTruthy();
  expect(screen.getByText(/Acting as @brand.test/)).toBeTruthy();
  expect(screen.queryByText("5 Unread")).toBeNull();
});
