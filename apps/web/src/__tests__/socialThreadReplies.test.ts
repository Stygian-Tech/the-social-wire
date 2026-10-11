import { describe, expect, it } from "bun:test";
import type { AppBskyFeedDefs } from "@atproto/api";
import { collectSocialThreadReplies, socialThreadReplyIndent } from "@/lib/socialThreadReplies";

function thread(key: string, replies: AppBskyFeedDefs.ThreadViewPost["replies"] = []): AppBskyFeedDefs.ThreadViewPost & { $type: "app.bsky.feed.defs#threadViewPost" } {
  return {
    $type: "app.bsky.feed.defs#threadViewPost",
    post: { uri: `at://did:plc:author/app.bsky.feed.post/${key}`, cid: key, author: { did: "did:plc:author", handle: "author.test" }, record: {}, indexedAt: "2026-10-11T00:00:00Z" },
    replies,
  };
}

describe("conversation reply rows", () => {
  it("retains API order, immediate parents, and depth across sibling branches", () => {
    const child = thread("child");
    const first = thread("first", [child]);
    const second = thread("second");
    const root = thread("root", [first, second]);
    const rows = collectSocialThreadReplies(root);
    expect(rows.map(row => [row.post.uri, row.parent.uri, row.depth])).toEqual([
      [first.post.uri, root.post.uri, 0],
      [child.post.uri, first.post.uri, 1],
      [second.post.uri, root.post.uri, 0],
    ]);
  });

  it("skips missing and blocked posts without inventing children or leaking their author", () => {
    const available = thread("available");
    const root = thread("root", [
      { $type: "app.bsky.feed.defs#notFoundPost", uri: "at://missing", notFound: true },
      { $type: "app.bsky.feed.defs#blockedPost", uri: "at://blocked", blocked: true, author: { did: "did:plc:blocked" } },
      available,
    ]);
    expect(collectSocialThreadReplies(root)).toEqual([{ post: available.post, parent: root.post, depth: 0 }]);
    expect(collectSocialThreadReplies(undefined)).toEqual([]);
  });

  it("guards repeated URIs, cycles, and excluded ancestors", () => {
    const ancestor = thread("ancestor");
    const child = thread("child");
    const root = thread("root", [child, child, ancestor]);
    child.replies = [root];
    expect(collectSocialThreadReplies(root, [ancestor.post.uri]).map(row => row.post.uri)).toEqual([child.post.uri]);
  });

  it("retains deep logical depth while bounding rows and visual indentation", () => {
    const root = thread("root");
    let parent = root;
    for (let depth = 0; depth < 120; depth++) {
      const child = thread(`reply${depth}`);
      parent.replies = [child];
      parent = child;
    }
    const rows = collectSocialThreadReplies(root);
    expect(rows).toHaveLength(100);
    expect(rows[99]?.depth).toBe(99);
    expect(socialThreadReplyIndent(0)).toBe("");
    expect(socialThreadReplyIndent(1)).toBe("ml-3 sm:ml-5");
    expect(socialThreadReplyIndent(2)).toBe("ml-6 sm:ml-10");
    expect(socialThreadReplyIndent(99)).toBe(socialThreadReplyIndent(3));
  });
});
