import { expect, it } from "bun:test";
import { podcastSubscriptionMatchesShow } from "@/lib/podcasts/subscriptionMatch";
import type { PodcastShow } from "@/lib/podcasts/client";
const show: PodcastShow = { id: "show", title: "Show", sourceKind: "rss", feedUrl: "https://example.org/rss?token=one" };
it("preserves distinct feed query parameters when removing a podcast", () => {
  expect(podcastSubscriptionMatchesShow({ category: "podcast", feedUrl: "https://example.org/rss?token=two" }, show, "imported", "canonical")).toBe(false);
  expect(podcastSubscriptionMatchesShow({ category: "podcast", feedUrl: "https://example.org/rss?token=one#fragment" }, show, "imported", "canonical")).toBe(true);
});
it("never removes News records even when their record key or normalized URL matches", () => {
  for (const category of [undefined, "news"]) {
    expect(podcastSubscriptionMatchesShow({ category, feedUrl: show.feedUrl }, show, "canonical", "canonical")).toBe(false);
  }
});
it("does not match malformed feed identities to each other", () => {
  expect(podcastSubscriptionMatchesShow({ category: "podcast", feedUrl: "https://" }, { ...show, feedUrl: "https://" }, "imported", "canonical")).toBe(false);
});
