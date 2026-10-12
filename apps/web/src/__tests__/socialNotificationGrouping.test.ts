import { describe, expect, it } from "bun:test";
import type { SocialNotification } from "@/lib/blueskySocialDiscoveryClient";
import { groupSocialNotifications } from "@/lib/socialNotificationGrouping";

const subject = "at://did:plc:viewer/app.bsky.feed.post/one";

function notification(id: string, overrides: Partial<SocialNotification> = {}): SocialNotification {
  return {
    uri: `at://did:plc:actor/app.bsky.feed.like/${id}`,
    cid: "bafyreia",
    author: { did: "did:plc:actor", handle: "actor.test" },
    reason: "like",
    reasonSubject: subject,
    record: {},
    isRead: false,
    indexedAt: "2026-10-11T12:00:00Z",
    ...overrides,
  };
}

describe("social notification grouping", () => {
  it("combines interactions by reason and target while retaining every event", () => {
    const first = notification("one");
    const second = notification("two", { author: { did: "did:plc:other", handle: "other.test" } });
    const repost = notification("repost", { reason: "repost" });
    const otherSubject = notification("other-post", { reasonSubject: `${subject}-other` });
    const groups = groupSocialNotifications([first, repost, second, otherSubject]);
    expect(groups.map(group => group.key)).toEqual([`like|${subject}`, `repost|${subject}`, `like|${subject}-other`]);
    expect(groups[0].notifications).toEqual([first, second]);
    expect(groups[0].authors.map(author => author.did)).toEqual(["did:plc:actor", "did:plc:other"]);
  });

  it("keeps distinct authors in encounter order and uses the first profile for a DID", () => {
    const first = notification("one");
    const sameAuthor = notification("two", { author: { ...first.author, displayName: "Updated" } });
    const groups = groupSocialNotifications([first, sameAuthor]);
    expect(groups[0].authors).toEqual([first.author]);
    expect(groups[0].notifications).toHaveLength(2);
  });

  it("marks a group read only when every retained event is read", () => {
    expect(groupSocialNotifications([notification("one", { isRead: true }), notification("two")])[0].isRead).toBe(false);
    expect(groupSocialNotifications([notification("one", { isRead: true }), notification("two", { isRead: true })])[0].isRead).toBe(true);
  });

  it("uses API encounter order for latest and group ordering without sorting timestamps", () => {
    const first = notification("one", { indexedAt: "2026-10-10T12:00:00Z" });
    const follow = notification("follow", { reason: "follow", reasonSubject: undefined });
    const second = notification("two");
    const groups = groupSocialNotifications([first, follow, second]);
    expect(groups.map(group => group.latest)).toEqual([first, follow]);
    expect(groups[0].notifications).toEqual([first, second]);
  });

  it("deduplicates overlapping pages while preserving distinct events from the same author", () => {
    const first = notification("one");
    const second = notification("two");
    const groups = groupSocialNotifications([first, second, { ...first }]);
    expect(groups).toHaveLength(1);
    expect(groups[0].notifications).toEqual([first, second]);
  });

  it.each(["reply", "mention", "quote", "subscribed-post"])("keeps every %s post individually visible even with a shared or missing subject", reason => {
    const first = notification("one", { reason, uri: "at://did:plc:actor/app.bsky.feed.post/one" });
    const second = notification("two", { reason, uri: "at://did:plc:actor/app.bsky.feed.post/two" });
    expect(groupSocialNotifications([first, second]).map(group => group.notifications)).toEqual([[first], [second]]);
    expect(groupSocialNotifications([{ ...first, reasonSubject: undefined }, { ...second, reasonSubject: undefined }])).toHaveLength(2);
  });

  it.each(["like", "repost", "like-via-repost", "repost-via-repost"])("resolves %s targets from strong references and isolates missing targets", reason => {
    const first = notification("one", { reason, reasonSubject: undefined, record: { subject: { uri: subject, cid: "bafyreia" } } });
    const second = notification("two", { reason, reasonSubject: undefined, record: { subject: { uri: subject, cid: "bafyreia" } } });
    expect(groupSocialNotifications([first, second])).toHaveLength(1);
    const another = { ...second, record: { subject: { uri: `${subject}-other`, cid: "bafyreia" } } };
    expect(groupSocialNotifications([first, another])).toHaveLength(2);
    expect(groupSocialNotifications([{ ...first, record: {} }, { ...second, record: {} }])).toHaveLength(2);
  });

  it("groups targetless account events by reason and handles empty input", () => {
    const groups = groupSocialNotifications([
      notification("one", { reason: "follow", reasonSubject: undefined }),
      notification("two", { reason: "follow", reasonSubject: undefined }),
      notification("three", { reason: "verified", reasonSubject: undefined }),
    ]);
    expect(groups.map(group => group.key)).toEqual(["follow|follow", "verified|verified"]);
    expect(groups[0].notifications).toHaveLength(2);
    expect(groupSocialNotifications([])).toEqual([]);
  });
});
