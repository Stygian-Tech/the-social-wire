import { describe, expect, it } from "bun:test";
import { addPublicationSubmitAction } from "@/lib/addPublicationFlow";

const resolvedFeed = {
  kind: "rss" as const,
  feedUrl: "https://example.com/feed.xml",
  title: "Example Feed",
};

describe("Add Publication flow", () => {
  it("resolves first, then subscribes with the same result without resolving again", () => {
    expect(
      addPublicationSubmitAction({
        input: " https://example.com ",
        resolved: null,
      })
    ).toEqual({ kind: "resolve", input: "https://example.com" });

    expect(
      addPublicationSubmitAction({
        input: "https://example.com",
        resolved: {
          input: "https://example.com",
          publication: resolvedFeed,
        },
      })
    ).toEqual({
      kind: "subscribe",
      input: "https://example.com",
      publication: resolvedFeed,
    });
  });

  it("resolves again after the input changes", () => {
    expect(
      addPublicationSubmitAction({
        input: "https://another.example",
        resolved: {
          input: "https://example.com",
          publication: resolvedFeed,
        },
      })
    ).toEqual({ kind: "resolve", input: "https://another.example" });
  });
});
