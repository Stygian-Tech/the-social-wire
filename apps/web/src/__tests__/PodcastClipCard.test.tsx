import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as auth from "@/hooks/useAuth";
import * as storage from "@/lib/auth";
import * as player from "@/components/Podcasts/PodcastPlayerProvider";
import * as assets from "@/lib/podcasts/clipAsset";
import * as publisher from "@/lib/podcasts/blueskyClipPublisher";
import * as profiles from "@/hooks/useViewerProfile";
import { PodcastClipCard } from "@/components/Podcasts/PodcastClipCard";
import type { PodcastClip } from "@/lib/podcasts/client";
import { SCOPE_RECOVERY_MESSAGE } from "@/lib/oauthScopeRecovery";
const restores: (() => void)[] = [];
beforeEach(() => {
  for (const [name, value] of Object.entries({ requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0), cancelAnimationFrame: clearTimeout })) {
    const original = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(globalThis, name, original); else Reflect.deleteProperty(globalThis, name); });
  }
});
afterEach(() => { cleanup(); for (const restore of restores.splice(0).reverse()) restore(); });
const clip: PodcastClip = { id: "private-clip", episodeId: "episode", title: "Prepared Clip", startSeconds: 10, endSeconds: 40, status: "complete", videoUrl: "/private/video", audioUrl: "/private/audio", createdAt: "2026-10-11" };
function setup() {
  const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const state = { oauth, stored: oauth.did };
  const signIn = mock(async (did: string) => { void did; });
  const authSpy = spyOn(auth, "useAuth").mockImplementation(() => ({ session: { did: state.oauth.did }, getOAuthSession: () => state.oauth, signIn }) as unknown as ReturnType<typeof auth.useAuth>);
  const stored = spyOn(storage, "getStoredOAuthDid").mockImplementation(() => state.stored);
  let pauses = 0;
  const audio = spyOn(player, "usePodcastPlayer").mockReturnValue({ playing: true, toggle: () => { pauses++; } } as ReturnType<typeof player.usePodcastPlayer>);
  const media = spyOn(assets, "fetchPodcastClipAsset").mockResolvedValue(new Blob(["rendered-video"], { type: "video/mp4" }));
  const create = spyOn(URL, "createObjectURL").mockReturnValue("blob:private-preview");
  const revoke = spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  const publish = spyOn(publisher, "publishBlueskyPodcastClip").mockResolvedValue({ uri: "at://did:plc:viewer/app.bsky.feed.post/post", cid: "cid" });
  const profile = spyOn(profiles, "useViewerProfile").mockReturnValue({ data: { did: oauth.did, displayName: "Podcast Fan", handle: "podcast.example" } } as ReturnType<typeof profiles.useViewerProfile>);
  restores.push(() => profile.mockRestore());
  restores.push(() => authSpy.mockRestore(), () => stored.mockRestore(), () => audio.mockRestore(), () => media.mockRestore(), () => create.mockRestore(), () => revoke.mockRestore(), () => publish.mockRestore());
  return { state, oauth, media, create, revoke, publish, signIn, pauses: () => pauses };
}
for (const failure of [new Error('Missing required scope "rpc:app.bsky.video.getUploadLimits?aud=did:web:video.bsky.app"'), new Error(SCOPE_RECOVERY_MESSAGE)]) {
  it(`offers explicit login recovery for clip publication: ${failure.message}`, async () => {
    const test = setup();
    test.publish.mockRejectedValue(failure);
    render(<PodcastClipCard clip={clip} />);
    fireEvent.click(screen.getByRole("button", { name: "Post to Bluesky" }));
    fireEvent.change(await screen.findByRole("textbox", { name: "Commentary" }), { target: { value: "Keep My Commentary" } });
    fireEvent.click(screen.getByRole("button", { name: "Review Post" }));
    fireEvent.click(screen.getByRole("button", { name: "Publish to Bluesky" }));
    const recover = await screen.findByRole("button", { name: "Log In Again" });
    expect(screen.getByRole("dialog").textContent).toContain(SCOPE_RECOVERY_MESSAGE);
    expect(screen.getByText("Keep My Commentary")).toBeTruthy();
    expect(test.signIn).not.toHaveBeenCalled();
    expect(test.publish).toHaveBeenCalledTimes(1);
    expect(test.revoke).not.toHaveBeenCalled();
    fireEvent.click(recover);
    await waitFor(() => expect(test.signIn).toHaveBeenCalledWith(test.oauth.did));
    expect(test.publish).toHaveBeenCalledTimes(1);
  });
}
it("keeps ordinary publication failures retryable without offering login recovery", async () => {
  const test = setup();
  test.publish.mockRejectedValue(new Error("Video Service Unavailable"));
  render(<PodcastClipCard clip={clip} />);
  fireEvent.click(screen.getByRole("button", { name: "Post to Bluesky" }));
  await screen.findByRole("textbox", { name: "Commentary" });
  fireEvent.click(screen.getByRole("button", { name: "Review Post" }));
  fireEvent.click(screen.getByRole("button", { name: "Publish to Bluesky" }));
  await waitFor(() => expect(screen.getByRole("dialog").textContent).toContain("Video Service Unavailable"));
  expect(screen.queryByRole("button", { name: "Log In Again" })).toBeNull();
  expect(screen.getByRole("button", { name: "Publish to Bluesky" }).hasAttribute("disabled")).toBe(false);
});
it("loads the actual private MP4 and pauses audio only when the user plays video", async () => {
  const test = setup();
  const view = render(<PodcastClipCard clip={clip} />);
  expect(test.media).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Preview Video" }));
  const video = await screen.findByLabelText("Video Preview: Prepared Clip");
  expect(video.getAttribute("src")).toBe("blob:private-preview");
  expect(video.hasAttribute("controls")).toBe(true); expect(video.hasAttribute("playsinline")).toBe(true);
  expect(test.media.mock.calls[0][0].clipId).toBe(clip.id); expect(test.pauses()).toBe(0);
  fireEvent.play(video); expect(test.pauses()).toBe(1);
  view.unmount(); expect(test.revoke).toHaveBeenCalledWith("blob:private-preview");
});
it("requires post review and publishes commentary with the same prepared MP4 and owner session", async () => {
  const test = setup(); render(<PodcastClipCard clip={clip} />);
  fireEvent.click(screen.getByRole("button", { name: "Post to Bluesky" }));
  const commentary = await screen.findByRole("textbox", { name: "Commentary" });
  fireEvent.change(commentary, { target: { value: "Listen to this!" } });
  expect(screen.getByText("Posting As Podcast Fan")).toBeTruthy(); expect(screen.getByText("@podcast.example")).toBeTruthy();
  expect(test.publish).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Review Post" }));
  expect(screen.getByText("Review Bluesky Post")).toBeTruthy();
  expect(screen.getByText("Listen to this!")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Publish to Bluesky" }));
  await waitFor(() => expect(test.publish).toHaveBeenCalledTimes(1));
  const args = test.publish.mock.calls[0][0]; expect(args.session).toBe(test.oauth); expect(args.text).toBe("Listen to this!"); expect(args.video.type).toBe("video/mp4"); expect(args.clip).toBe(clip);
  await screen.findByText(/Published to Bluesky/);
});
it("discards deferred media on owner switch and clears preview URLs on cross-tab identity changes", async () => {
  const test = setup(); let resolve: (blob: Blob) => void = () => {};
  test.media.mockImplementation(() => new Promise(done => { resolve = done; }));
  const view = render(<PodcastClipCard clip={clip} />);
  fireEvent.click(screen.getByRole("button", { name: "Preview Video" }));
  test.state.oauth = { did: "did:plc:other" } as unknown as OAuthSession; test.state.stored = test.state.oauth.did;
  view.rerender(<PodcastClipCard clip={clip} />);
  expect(test.media.mock.calls[0][0].signal?.aborted).toBe(true);
  resolve(new Blob(["old-account"], { type: "video/mp4" }));
  await waitFor(() => expect(screen.getByRole("button", { name: "Preview Video" }).hasAttribute("disabled")).toBe(false));
  expect(test.create).not.toHaveBeenCalled();
  test.media.mockResolvedValue(new Blob(["new-account"], { type: "video/mp4" }));
  fireEvent.click(screen.getByRole("button", { name: "Preview Video" })); await screen.findByLabelText("Video Preview: Prepared Clip");
  fireEvent(window, new window.StorageEvent("storage", { key: "@@atproto/oauth-client-browser(sub)" }));
  await waitFor(() => expect(screen.queryByLabelText("Video Preview: Prepared Clip")).toBeNull());
  expect(test.revoke).toHaveBeenCalledWith("blob:private-preview");
});
it("failed exports cannot be previewed or posted and offer retry", () => {
  setup(); render(<PodcastClipCard clip={{ ...clip, status: "failed", videoUrl: undefined }} />);
  expect(screen.getByRole("button", { name: "Preview Video" }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Post to Bluesky" }).hasAttribute("disabled")).toBe(true);
  expect(screen.getByRole("button", { name: "Retry Exports" })).toBeTruthy();
});

it("cancels an upload while retaining the prepared preview and commentary review", async () => {
  const test = setup();
  test.publish.mockImplementation(args => new Promise((_resolve, reject) => {
    args.signal?.addEventListener("abort", () => reject(args.signal?.reason), { once: true });
  }));
  render(<PodcastClipCard clip={clip} />);
  fireEvent.click(screen.getByRole("button", { name: "Post to Bluesky" }));
  fireEvent.change(await screen.findByRole("textbox", { name: "Commentary" }), { target: { value: "Keep this commentary" } });
  fireEvent.click(screen.getByRole("button", { name: "Review Post" }));
  fireEvent.click(screen.getByRole("button", { name: "Publish to Bluesky" }));
  fireEvent.click(await screen.findByRole("button", { name: "Cancel Upload" }));
  await waitFor(() => expect(test.publish.mock.calls[0][0].signal?.aborted).toBe(true));
  expect(screen.getByText("Keep this commentary")).toBeTruthy();
  expect(screen.getByRole("button", { name: "Publish to Bluesky" }).hasAttribute("disabled")).toBe(false);
  expect(test.revoke).not.toHaveBeenCalled();
});


it("links a verified existing Bluesky post after a cross-session commentary conflict", async () => {
  const test = setup();
  const uri = "at://did:plc:viewer/app.bsky.feed.post/existing";
  test.publish.mockRejectedValue(new publisher.PodcastClipAlreadyPublishedError(uri, "cid"));
  render(<PodcastClipCard clip={clip} />);
  fireEvent.click(screen.getByRole("button", { name: "Post to Bluesky" }));
  await screen.findByRole("textbox", { name: "Commentary" });
  fireEvent.click(screen.getByRole("button", { name: "Review Post" }));
  fireEvent.click(screen.getByRole("button", { name: "Publish to Bluesky" }));
  const link = await screen.findByRole("link", { name: "View Post" });
  expect(link.getAttribute("href")).toBe(`/social/post?uri=${encodeURIComponent(uri)}`);
  expect(screen.queryByRole("dialog")).toBeNull();
});
