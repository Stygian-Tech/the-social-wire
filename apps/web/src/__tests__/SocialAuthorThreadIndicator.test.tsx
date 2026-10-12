import { afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { AppBskyFeedDefs, ModerationOpts } from "@atproto/api";
import * as Thread from "@/hooks/useBlueskyPostThread";
import { SocialAuthorThreadIndicator } from "@/components/Social/SocialAuthorThreadIndicator";
const moderation: ModerationOpts = { userDid: "did:plc:viewer", prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] } };
const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
const post = { $type: "app.bsky.feed.defs#postView" as const, uri: "at://did:plc:op/app.bsky.feed.post/root", cid, author: { did: "did:plc:op", handle: "op.test" }, record: { $type: "app.bsky.feed.post", text: "root", createdAt: "2026-10-10T00:00:00Z" }, indexedAt: "2026-10-10T00:00:00Z", replyCount: 1 };
const child = { ...post, uri: `${post.uri}child`, replyCount: 0, record: { ...post.record, reply: { root: { uri: post.uri, cid }, parent: { uri: post.uri, cid } } } };
const thread: AppBskyFeedDefs.ThreadViewPost = { $type: "app.bsky.feed.defs#threadViewPost", post, replies: [{ $type: "app.bsky.feed.defs#threadViewPost", post: child, replies: [] }] };
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(fn => fn()); });
function stub(data?: AppBskyFeedDefs.ThreadViewPost, isError = false) {
  const hook = spyOn(Thread, "useBlueskyPostThread").mockReturnValue({ data: data ? { thread: data } : undefined, isError } as ReturnType<typeof Thread.useBlueskyPostThread>);
  restores.push(() => hook.mockRestore()); return hook;
}
describe("OP thread indicator", () => {
  it("shows fetched count independently from total replies and opens the root", () => {
    stub(); const open = mock(() => {});
    render(<SocialAuthorThreadIndicator item={{ post }} thread={thread} moderation={moderation} onOpen={open} />);
    fireEvent.click(screen.getByRole("button", { name: "Open OP Thread (2 Posts)" }));
    expect(open).toHaveBeenCalledWith(post.uri);
  });
  it("labels incomplete chains as a minimum and suppresses stale error data", () => {
    const hook = stub({ ...thread, post: { ...post, replyCount: 10 } }); const open = mock(() => {});
    const view = render(<SocialAuthorThreadIndicator item={{ post }} moderation={moderation} onOpen={open} />);
    expect(screen.getByRole("button", { name: "Open OP Thread (At Least 2 Posts)" }).textContent).toContain("2+ Posts");
    hook.mockReturnValue({ data: { thread }, isError: true } as ReturnType<typeof Thread.useBlueskyPostThread>);
    view.rerender(<SocialAuthorThreadIndicator item={{ post }} moderation={moderation} onOpen={open} />);
    expect(screen.queryByRole("button")).toBeNull();
  });
  it("defers requests until visible and disconnects the observer", () => {
    const hook = stub(); let intersect: IntersectionObserverCallback | undefined;
    const disconnect = mock(() => {}); const observe = mock(() => {});
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, "IntersectionObserver");
    Object.defineProperty(globalThis, "IntersectionObserver", { configurable: true, value: class { constructor(callback: IntersectionObserverCallback) { intersect = callback; } observe = observe; disconnect = disconnect; } });
    restores.push(() => { if (descriptor) Object.defineProperty(globalThis, "IntersectionObserver", descriptor); else Reflect.deleteProperty(globalThis, "IntersectionObserver"); });
    render(<SocialAuthorThreadIndicator item={{ post }} moderation={moderation} onOpen={() => {}} />);
    expect(hook.mock.calls.at(-1)?.[0]).toBeUndefined(); expect(observe).toHaveBeenCalledTimes(1);
    act(() => intersect!([{ isIntersecting: true } as IntersectionObserverEntry], {} as IntersectionObserver));
    expect(hook.mock.calls.at(-1)?.[0]).toBe(post.uri); expect(disconnect).toHaveBeenCalled();
  });
  it("suppresses a hidden root or a participant's self-reply chain", () => {
    stub(); const hidden = { ...moderation, prefs: { ...moderation.prefs, hiddenPosts: [post.uri] } };
    const view = render(<SocialAuthorThreadIndicator item={{ post }} thread={thread} moderation={hidden} onOpen={() => {}} />);
    expect(screen.queryByRole("button")).toBeNull();
    view.rerender(<SocialAuthorThreadIndicator item={{ post: child }} thread={{ ...thread, post: child, replies: [] }} moderation={moderation} onOpen={() => {}} />);
    expect(screen.queryByRole("button")).toBeNull();
  });
});
