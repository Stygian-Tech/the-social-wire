import { afterEach, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { ModerationOpts } from "@atproto/api";
import * as Catalog from "@/hooks/useBlueskySocialCatalog";
import * as Timeline from "@/hooks/useBlueskyProfileTimeline";
import * as Publications from "@/components/Account/MyPublicationsSection";
import * as Auth from "@/hooks/useAuth";
import { ProfileContent } from "@/components/Account/ProfileContent";
import { ProfileTimeline } from "@/components/Account/ProfileTimeline";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";

const safety: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const restores: (() => void)[] = [];
let timeline: ReturnType<typeof Timeline.useBlueskyProfileTimeline>;
let catalog: ReturnType<typeof Catalog.useBlueskySocialCatalog>;
const more = mock(async () => undefined);
const retry = mock(async () => undefined);
beforeEach(() => {
  more.mockClear(); retry.mockClear();
  timeline = { data: { pages: [{ feed: [] }], pageParams: [undefined] }, isPending: false, isError: false, hasNextPage: false, refetch: retry, fetchNextPage: more } as unknown as typeof timeline;
  catalog = { data: { moderation: safety, feeds: [] }, isPending: false, isError: false, refetch: mock(async () => ({ isError: false })) } as unknown as typeof catalog;
  const spies = [spyOn(Timeline, "useBlueskyProfileTimeline").mockImplementation(() => timeline), spyOn(Catalog, "useBlueskySocialCatalog").mockImplementation(() => catalog), spyOn(Publications, "MyPublicationsSection").mockImplementation(() => <p>Publication Cards</p>), spyOn(Auth, "useAuth").mockReturnValue({ session: { did: safety.userDid }, signIn: mock(async () => undefined) } as unknown as ReturnType<typeof Auth.useAuth>)];
  restores.push(...spies.map(spy => () => spy.mockRestore()));
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); window.history.replaceState(null, "", "/"); });
describe("Profile content", () => {
  it("switches between read-only tabs and publications without showing settings on the profile", () => {
    render(<ProfileContent />);
    const navigation = screen.getByRole("navigation", { name: "Profile Content" });
    expect(navigation.classList.contains("floating-glass")).toBe(true);
    expect(navigation.classList.contains("m-2")).toBe(true);
    expect(navigation.classList.contains("top-2")).toBe(true);
    expect(navigation.classList.contains("border-y")).toBe(false);
    expect(screen.getByRole("button", { name: "Posts" }).getAttribute("aria-pressed")).toBe("true");
    fireEvent.click(screen.getByRole("button", { name: "Replies" }));
    expect(screen.getByText("No Replies to Show")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Media" }));
    expect(screen.getByText("No Media to Show")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Likes" }));
    expect(screen.getByText("No Likes to Show")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Publications" }));
    expect(screen.getByText("Publication Cards")).toBeTruthy();
    expect(screen.queryByText("Settings")).toBeNull();
  });
  it("preserves the publications deep link", () => {
    window.history.replaceState(null, "", "/me#publications");
    render(<ProfileContent />);
    expect(screen.getByText("Publication Cards")).toBeTruthy();
  });
  it("allows pagination when a filtered reply page is empty", () => {
    timeline = { ...timeline, hasNextPage: true };
    render(<ProfileTimeline section="replies" />);
    fireEvent.click(screen.getByRole("button", { name: "Load More" }));
    expect(more).toHaveBeenCalledTimes(1);
  });
  it("offers permission recovery and hides content when moderation fails", () => {
    catalog = { ...catalog, isError: true, error: new Error(SCOPE_RECOVERY_MESSAGE) } as typeof catalog;
    render(<ProfileTimeline section="likes" />);
    expect(screen.getByRole("alert").textContent).toContain(SCOPE_RECOVERY_MESSAGE);
    expect(screen.getByRole("button", { name: "Log In Again" })).toBeTruthy();
    expect(screen.queryByText("No Likes to Show")).toBeNull();
    expect(screen.queryByRole("article")).toBeNull();
  });
});
