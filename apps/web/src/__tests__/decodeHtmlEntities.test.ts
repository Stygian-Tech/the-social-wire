import { describe, expect, it } from "bun:test";

import { decodeHtmlEntities } from "@/lib/decodeHtmlEntities";

describe("decodeHtmlEntities", () => {
  it("decodes decimal numeric entities in titles", () => {
    expect(
      decodeHtmlEntities(
        "Hackers are learning to exploit chatbot &#8216;personalities&#8217;"
      )
    ).toBe("Hackers are learning to exploit chatbot ‘personalities’");
  });

  it("decodes named entities", () => {
    expect(decodeHtmlEntities("Tom &amp; Jerry")).toBe("Tom & Jerry");
  });

  it("strips HTML tags", () => {
    expect(decodeHtmlEntities("<i>Hello</i> &amp; world")).toBe("Hello & world");
  });

  it("leaves plain text unchanged", () => {
    expect(decodeHtmlEntities("Already clean")).toBe("Already clean");
  });
});
