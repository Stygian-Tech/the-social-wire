import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Workspace from "@/hooks/useSocialWorkspace";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Profile from "@/hooks/useBlueskyProfile";
import * as Atproto from "@/lib/atprotoClient";
import { SocialProfileLink } from "@/components/Social/SocialProfileLink";
import { socialProfileActorFromUrl } from "@/lib/socialProfileNavigation";

const did = "did:plc:viewer";
const actor = "did:plc:other";
const moderation: ModerationOpts = { userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const follow = mock(async () => ({ uri: `at://${did}/app.bsky.graph.follow/one`, cid: "cid" }));
const restores: (() => void)[] = [];
let cache: QueryClient;
let profileValue = { did: actor, handle: "other.test", displayName: "Other Person", description: "A profile biography", viewer: {} };
let profileLookup: ReturnType<typeof spyOn>;
beforeEach(() => {
  for (const [name, value] of Object.entries({ HTMLElement: window.HTMLElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
  }
  cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  follow.mockClear();
  profileValue = { did: actor, handle: "other.test", displayName: "Other Person", description: "A profile biography", viewer: {} };
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did } } as ReturnType<typeof Auth.useAuth>);
  const workspace = spyOn(Workspace, "useSocialWorkspaceSession").mockReturnValue({ did, sequence: 0, requireSession: () => ({ did } as unknown as OAuthSession) });
  const catalog = spyOn(Catalog, "useBlueskySocialCatalog").mockReturnValue({ data: { moderation }, isError: false } as ReturnType<typeof Catalog.useBlueskySocialCatalog>);
  const profile = spyOn(Profile, "useBlueskyProfile").mockImplementation(() => ({ data: profileValue, isError: false, isPending: false }) as ReturnType<typeof Profile.useBlueskyProfile>);
  profileLookup = profile;
  const agent = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ follow } as unknown as ReturnType<typeof Atproto.createOAuthAgent>);
  restores.push(() => auth.mockRestore(), () => workspace.mockRestore(), () => catalog.mockRestore(), () => profile.mockRestore(), () => agent.mockRestore());
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
function show() {
  return render(<QueryClientProvider client={cache}><SocialProfileLink actor={actor}>@other.test</SocialProfileLink></QueryClientProvider>);
}

it("loads a profile only on hover and follows from the card without nesting the button in a link", async () => {
  show();
  const link = screen.getByRole("link", { name: "@other.test" });
  expect(link.getAttribute("href")).toBe("/social/profile?actor=did%3Aplc%3Aother&returnTo=%2Fsocial");
  expect(link.getAttribute("target")).toBeNull();
  expect(profileLookup).not.toHaveBeenCalled();
  fireEvent.mouseEnter(link);
  expect(await screen.findByText("A profile biography")).toBeTruthy();
  expect(profileLookup).toHaveBeenCalledWith(actor, moderation);
  const button = screen.getByRole("button", { name: "Follow @other.test" });
  expect(button.closest("a")).toBeNull();
  fireEvent.click(button);
  await waitFor(() => expect(follow).toHaveBeenCalledTimes(1));
  expect(follow).toHaveBeenCalledWith(actor);
  expect(await screen.findByRole("button", { name: "Following @other.test" })).toBeTruthy();
});

it("opens on keyboard focus and withholds blocked profiles", async () => {
  profileValue = { ...profileValue, viewer: { blockedBy: true } };
  show();
  fireEvent.focus(screen.getByRole("link", { name: "@other.test" }));
  expect(await screen.findByText("Profile withheld by your moderation settings.")).toBeTruthy();
  expect(screen.queryByText("A profile biography")).toBeNull();
  expect(screen.queryByRole("button", { name: /Follow/ })).toBeNull();
});

it("recognizes only valid Bluesky profile URLs for native previews", () => {
  expect(socialProfileActorFromUrl("https://bsky.app/profile/alice.test")).toBe("alice.test");
  expect(socialProfileActorFromUrl("https://bsky.app/profile/did%3Aplc%3Aalice/")).toBe("did:plc:alice");
  for (const url of ["https://bsky.app/profile/alice.test/post/one", "https://bsky.app.evil.test/profile/alice.test", "https://user:pass@bsky.app/profile/alice.test", "http://bsky.app/profile/alice.test", "https://bsky.app/profile/%2Funsafe", "https://bsky.app/profile/%ZZ"]) expect(socialProfileActorFromUrl(url)).toBeUndefined();
});
