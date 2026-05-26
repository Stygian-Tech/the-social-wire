import { describe, expect, it } from "bun:test";

import {
  extractOEmbedEndpointFromHtml,
  isUsableOEmbedResponse,
  oEmbedRequestUrl,
  parseOEmbedJson,
  wordPressOEmbedEndpoint,
} from "@/lib/oEmbed";

describe("oEmbed helpers", () => {
  it("extracts discovery link from publisher HTML", () => {
    const html = `
      <html><head>
        <link rel="alternate" type="application/json+oembed"
          href="https://publish.example/oembed?format=json" title="oEmbed Profile" />
      </head></html>`;
    expect(extractOEmbedEndpointFromHtml(html)).toBe(
      "https://publish.example/oembed?format=json"
    );
  });

  it("builds WordPress oEmbed endpoint from origin", () => {
    expect(wordPressOEmbedEndpoint("https://blog.example")).toBe(
      "https://blog.example/wp-json/oembed/1.0/embed"
    );
  });

  it("builds oEmbed request URL with page url param", () => {
    expect(
      oEmbedRequestUrl("https://publish.example/oembed", "https://article.example/p/1")
    ).toBe(
      "https://publish.example/oembed?url=https%3A%2F%2Farticle.example%2Fp%2F1&format=json"
    );
  });

  it("parses valid oEmbed JSON", () => {
    const parsed = parseOEmbedJson({
      type: "rich",
      html: "<iframe src=\"https://cdn.example/embed\"></iframe>",
      title: "Hello",
    });
    expect(parsed?.type).toBe("rich");
    expect(parsed?.html).toContain("iframe");
  });

  it("rejects link-only oEmbed for inline reader use", () => {
    expect(
      isUsableOEmbedResponse({
        type: "link",
        title: "Article",
        thumbnail_url: "https://cdn.example/thumb.jpg",
      })
    ).toBe(false);
  });

  it("accepts rich oEmbed with iframe html", () => {
    expect(
      isUsableOEmbedResponse({
        type: "rich",
        html: '<iframe src="https://www.youtube.com/embed/x"></iframe>',
      })
    ).toBe(true);
  });

  it("accepts photo oEmbed with https url", () => {
    expect(
      isUsableOEmbedResponse({
        type: "photo",
        url: "https://cdn.example/photo.jpg",
      })
    ).toBe(true);
  });
});
