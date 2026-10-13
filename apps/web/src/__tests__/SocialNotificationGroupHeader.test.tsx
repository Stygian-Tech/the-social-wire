import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import type { ModerationOpts } from "@atproto/api";
import * as Images from "@/hooks/useCachedImageUrl";
import { SocialNotificationGroupHeader } from "@/components/Social/SocialNotificationGroupHeader";
import type { SocialNotification } from "@/lib/blueskySocialDiscoveryClient";
import { groupSocialNotifications } from "@/lib/socialNotificationGrouping";
import { socialProfilePageHref } from "@/lib/socialProfileNavigation";

const labelerDid = "did:plc:labeler";
const moderation: ModerationOpts = {
  userDid: "did:plc:viewer",
  prefs: { adultContentEnabled: false, labels: {}, labelers: [{ did: labelerDid, labels: {} }], mutedWords: [], hiddenPosts: [] },
};
const bob = { did: "did:plc:bob", handle: "bob.test", displayName: "Bob", avatar: "https://images.test/bob.jpg" };
const carol = { did: "did:plc:carol", handle: "carol.test", displayName: "Carol", avatar: "https://images.test/carol.jpg" };
const dan = { did: "did:plc:dan", handle: "dan.test", displayName: "Dan" };
const restores: (() => void)[] = [];

function notification(id: string, author: SocialNotification["author"], isRead = true): SocialNotification {
  return { uri: `at://${author.did}/app.bsky.graph.follow/${id}`, cid: "bafyreia", author, reason: "follow", record: {}, isRead, indexedAt: "2026-10-11T12:00:00Z" };
}

beforeEach(() => {
  const images = spyOn(Images, "useCachedImageUrl").mockImplementation(src => ({ objectUrl: src ?? undefined, failed: false }));
  restores.push(() => images.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

it("discloses each unique person with their internal profile link", () => {
  const group = groupSocialNotifications([
    notification("one", bob), notification("two", carol), notification("three", bob), notification("four", dan),
  ])[0];
  render(<SocialNotificationGroupHeader group={group} moderation={moderation} />);
  const summary = screen.getByLabelText("Show People: Bob and Carol + 1");
  expect(summary.parentElement?.hasAttribute("open")).toBe(false);
  fireEvent.click(summary);
  expect(summary.parentElement?.hasAttribute("open")).toBe(true);
  expect(screen.getAllByRole("link")).toHaveLength(8);
  for (const author of [bob, carol, dan]) {
    expect(screen.getByRole("link", { name: author.displayName }).getAttribute("href")).toBe(socialProfilePageHref(author.did, "/social/notifications"));
  }
  expect(screen.getByText("Followed You")).toBeTruthy();
});

it("withholds moderated avatars and display names in both summary and disclosed people", () => {
  const hidden = { ...bob, labels: [{ src: labelerDid, uri: bob.did, val: "!hide", cts: "2026-10-11T00:00:00Z" }] };
  const group = groupSocialNotifications([notification("one", hidden), notification("two", carol)])[0];
  const { container } = render(<SocialNotificationGroupHeader group={group} moderation={moderation} />);
  fireEvent.click(screen.getByLabelText("Show People: bob.test and Carol"));
  expect(screen.queryByText("Bob")).toBeNull();
  expect(screen.getByRole("link", { name: "bob.test" }).getAttribute("href")).toBe(socialProfilePageHref(bob.did, "/social/notifications"));
  expect(container.querySelector(`img[src="${bob.avatar}"]`)).toBeNull();
  expect(container.querySelectorAll(`img[src="${carol.avatar}"]`)).toHaveLength(2);
});

it("shows unread for any unread member and removes it after all events are read", () => {
  const events = [notification("one", bob), notification("two", carol, false)];
  const { rerender } = render(<SocialNotificationGroupHeader group={groupSocialNotifications(events)[0]} moderation={moderation} />);
  expect(screen.getByText("Unread")).toBeTruthy();
  rerender(<SocialNotificationGroupHeader group={groupSocialNotifications(events.map(event => ({ ...event, isRead: true })))[0]} moderation={moderation} />);
  expect(screen.queryByText("Unread")).toBeNull();
});

it("links a single person directly without a disclosure", () => {
  render(<SocialNotificationGroupHeader group={groupSocialNotifications([notification("one", bob)])[0]} moderation={moderation} />);
  expect(screen.getByRole("link", { name: "Bob" }).getAttribute("href")).toBe(socialProfilePageHref(bob.did, "/social/notifications"));
  expect(screen.queryByLabelText(/Show People/)).toBeNull();
});
