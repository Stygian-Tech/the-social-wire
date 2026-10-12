import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { AppBskyActorDefs, ModerationOpts } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Auth from "@/hooks/useAuth";
import * as Workspace from "@/hooks/useSocialWorkspace";
import * as Atproto from "@/lib/atprotoClient";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
import { SocialExplorePersonCard } from "@/components/Social/SocialExplorePersonCard";

const alice = "did:plc:alice";
const actor: AppBskyActorDefs.ProfileView = { did: "did:plc:other", handle: "other.test", displayName: "Other" };
const moderation = (did: string): ModerationOpts => ({ userDid: did, prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } });
let viewer: string;
let oauth: string;
let cache: QueryClient;
const follow = mock(async (did: string) => { void did; return { uri: `at://${alice}/app.bsky.graph.follow/one`, cid: "cid" }; });
const restores: (() => void)[] = [];
function Wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={cache}>{children}</QueryClientProvider>; }
function card(person = actor) { return <SocialExplorePersonCard actor={person} moderation={moderation(viewer)} returnTo="/social/explore?q=trees&type=people" />; }
beforeEach(() => {
  viewer = alice; oauth = alice;
  follow.mockReset(); follow.mockResolvedValue({ uri: `at://${alice}/app.bsky.graph.follow/one`, cid: "cid" });
  cache = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity }, mutations: { retry: false } } });
  const workspace = spyOn(Workspace, "useSocialWorkspaceSession").mockImplementation(() => ({ did: viewer, sequence: 0, requireSession: () => ({ did: oauth } as OAuthSession) }));
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: viewer }, signIn: async () => {} } as unknown as ReturnType<typeof Auth.useAuth>));
  restores.push(() => auth.mockRestore());
  const agent = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ follow } as unknown as ReturnType<typeof Atproto.createOAuthAgent>);
  restores.push(() => workspace.mockRestore(), () => agent.mockRestore());
});
afterEach(() => { cleanup(); cache.clear(); restores.splice(0).reverse().forEach(restore => restore()); });

it("follows once, prevents duplicate pending clicks and keeps action outside the profile link", async () => {
  let finish!: (value: { uri: string; cid: string }) => void;
  follow.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  render(card(), { wrapper: Wrapper });
  const button = screen.getByRole("button", { name: "Follow @other.test" });
  expect(button.closest("a")).toBeNull();
  expect(screen.getByRole("link").getAttribute("href")).toContain("returnTo=");
  fireEvent.click(button); fireEvent.click(button);
  await waitFor(() => expect(follow).toHaveBeenCalledTimes(1));
  expect(follow).toHaveBeenCalledWith(actor.did);
  expect(button.hasAttribute("disabled")).toBe(true);
  await act(async () => finish({ uri: `at://${alice}/app.bsky.graph.follow/one`, cid: "cid" }));
  expect(await screen.findByRole("button", { name: "Following @other.test" })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Following @other.test" }).hasAttribute("disabled")).toBe(true);
});

it("shows failures without marking the person followed and allows retry", async () => {
  follow.mockRejectedValueOnce(new Error("Service unavailable"));
  render(card(), { wrapper: Wrapper });
  fireEvent.click(screen.getByRole("button", { name: "Follow @other.test" }));
  expect(await screen.findByRole("alert")).toBeTruthy();
  const retry = screen.getByRole("button", { name: "Follow @other.test" });
  expect(retry.hasAttribute("disabled")).toBe(false);
  fireEvent.click(retry);
  await screen.findByRole("button", { name: "Following @other.test" });
  expect(follow).toHaveBeenCalledTimes(2);
});

it("rejects mismatched OAuth before the PDS write", async () => {
  oauth = "did:plc:bob";
  render(card(), { wrapper: Wrapper });
  fireEvent.click(screen.getByRole("button", { name: "Follow @other.test" }));
  expect(await screen.findByRole("alert")).toBeTruthy();
  expect(follow).not.toHaveBeenCalled();
});

it("does not recreate removed account caches after a late follow completes", async () => {
  let finish!: (value: { uri: string; cid: string }) => void;
  follow.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  const view = render(card(), { wrapper: Wrapper });
  fireEvent.click(screen.getByRole("button", { name: "Follow @other.test" }));
  await waitFor(() => expect(follow).toHaveBeenCalledTimes(1));
  viewer = "did:plc:bob"; oauth = viewer;
  act(() => { cache.removeQueries({ queryKey: ["blueskySocial", alice] }); view.rerender(card()); });
  await act(async () => finish({ uri: `at://${alice}/app.bsky.graph.follow/one`, cid: "cid" }));
  expect(cache.getQueryCache().findAll({ queryKey: ["blueskySocial", alice] })).toHaveLength(0);
  expect(screen.getByRole("button", { name: "Follow @other.test" })).toBeTruthy();
});

it("renders scope recovery and preserves already-followed and self states", async () => {
  follow.mockRejectedValueOnce(new Error(SCOPE_RECOVERY_MESSAGE));
  const view = render(card(), { wrapper: Wrapper });
  fireEvent.click(screen.getByRole("button", { name: "Follow @other.test" }));
  await screen.findByText(SCOPE_RECOVERY_MESSAGE);
  expect(screen.getByRole("button", { name: "Log In Again" })).toBeTruthy();
  view.unmount(); cache.clear();
  const followed = render(card({ ...actor, viewer: { following: `at://${alice}/app.bsky.graph.follow/existing` } }), { wrapper: Wrapper });
  expect(screen.getByRole("button", { name: "Following @other.test" }).hasAttribute("disabled")).toBe(true);
  followed.rerender(card({ ...actor, did: alice }));
  expect(screen.queryByRole("button", { name: /Follow/ })).toBeNull();
});
