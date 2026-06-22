import { describe, expect, it } from "bun:test";

import {
  extractStandardSiteArticleAtUriFromHtml,
  extractOEmbedEndpointFromHtml,
  isUsableOEmbedResponse,
  isVideoEmbedIframeSrc,
  oEmbedHtmlLayout,
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

  it("extracts standard.site article AT URI from head metadata", () => {
    const html = `
      <html><head>
        <meta name="at-uri" content="at://did:plc:author/site.standard.document/post123" />
      </head><body>
        <meta name="at-uri" content="at://did:plc:wrong/site.standard.document/body" />
      </body></html>`;
    expect(extractStandardSiteArticleAtUriFromHtml(html)).toBe(
      "at://did:plc:author/site.standard.document/post123"
    );
  });

  it("ignores non-standard.site AT URI head metadata", () => {
    const html = `
      <html><head>
        <meta name="at-uri" content="at://did:plc:author/app.bsky.feed.post/post123" />
      </head></html>`;
    expect(extractStandardSiteArticleAtUriFromHtml(html)).toBe(null);
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

  it("detects video provider iframes", () => {
    expect(
      isVideoEmbedIframeSrc("https://www.youtube.com/embed/abc123")
    ).toBe(true);
    expect(isVideoEmbedIframeSrc("https://adventures.example/a/post")).toBe(false);
  });

  it("uses article layout for non-video rich embeds", () => {
    const html =
      '<blockquote>Preview</blockquote><iframe src="https://adventures.example/a/post" width="600" height="400"></iframe>';
    expect(oEmbedHtmlLayout(html)).toBe("article");
  });
});
