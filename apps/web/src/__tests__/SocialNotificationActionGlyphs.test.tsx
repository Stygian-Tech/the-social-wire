import { afterEach, expect, it } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import type { ModerationOpts } from "@atproto/api";
import { SocialNotificationGroupHeader } from "@/components/Social/SocialNotificationGroupHeader";
import type { SocialNotification } from "@/lib/blueskySocialDiscoveryClient";
import { groupSocialNotifications } from "@/lib/socialNotificationGrouping";

const moderation: ModerationOpts = {
  userDid: "did:plc:viewer",
  prefs: { adultContentEnabled: false, labels: {}, labelers: [], mutedWords: [], hiddenPosts: [] },
};

function renderReason(reason: string) {
  const notification: SocialNotification = {
    uri: "at://did:plc:bob/app.bsky.feed.like/one", cid: "bafyreia",
    author: { did: "did:plc:bob", handle: "bob.test", displayName: "Bob" },
    reason, record: {}, isRead: false, indexedAt: "2026-10-11T12:00:00Z",
  };
  return render(<SocialNotificationGroupHeader group={groupSocialNotifications([notification])[0]} moderation={moderation} />);
}

afterEach(cleanup);

it.each([
  ["like", "Liked Your Post", "lucide-heart"],
  ["reply", "Replied to Your Post", "lucide-message-circle"],
  ["repost", "Reposted Your Post", "lucide-repeat-2"],
  ["quote", "Quoted Your Post", "lucide-quote"],
  ["like-via-repost", "Liked a Post You Reposted", "lucide-heart"],
  ["repost-via-repost", "Reposted a Post You Reposted", "lucide-repeat-2"],
])("shows the %s glyph beside its readable action label", (reason, label, iconClass) => {
  renderReason(reason);
  const action = screen.getByText(label);
  const glyph = action.querySelector("svg");
  expect(glyph?.classList.contains(iconClass)).toBe(true);
  expect(glyph?.getAttribute("aria-hidden")).toBe("true");
  expect(glyph?.classList.contains("shrink-0")).toBe(true);
  expect(screen.getByRole("link", { name: "Bob" })).toBeTruthy();
  expect(screen.getByText("Unread")).toBeTruthy();
});

it.each([
  ["follow", "Followed You"],
  ["future-action", "Sent a Notification"],
])("preserves %s action labels without an unrelated glyph", (reason, label) => {
  renderReason(reason);
  expect(screen.getByText(label).querySelector("svg")).toBeNull();
});
