import { describe, expect, it } from "bun:test";

import {
  normalizeWireFeedbackUrl,
  WIRE_ARTICLE_FEEDBACK_COLLECTION,
  wireFeedbackRkey,
} from "@/lib/wireArticleFeedback";

describe("Wire article feedback records", () => {
  it("uses the Social Wire collection and a stable per-URL rkey", async () => {
    expect(WIRE_ARTICLE_FEEDBACK_COLLECTION).toBe(
      "app.thesocialwire.wireFeedback",
    );
    expect(await wireFeedbackRkey("https://example.com/story#section")).toBe(
      await wireFeedbackRkey("https://example.com/story"),
    );
    expect(await wireFeedbackRkey("https://example.com/story")).toHaveLength(64);
  });

  it("accepts public article URLs and rejects other schemes", () => {
    expect(normalizeWireFeedbackUrl("https://example.com/story#comments")).toBe(
      "https://example.com/story",
    );
    expect(normalizeWireFeedbackUrl("at://did:plc:test/app.bsky.feed.post/1")).toBeNull();
  });
});
