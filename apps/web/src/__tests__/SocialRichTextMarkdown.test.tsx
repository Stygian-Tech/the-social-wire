import { describe, expect, it } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AppBskyFeedPost, AppBskyRichtextFacet } from "@atproto/api";
import { SocialRichText } from "@/components/Social/SocialRichText";
import { socialMarkdownBlocks, socialMarkdownInline } from "@/components/Social/socialMarkdown";

function facet(text: string, label: string, feature: AppBskyRichtextFacet.Main["features"][number]): AppBskyRichtextFacet.Main {
  const start = text.indexOf(label);
  return { index: { byteStart: new TextEncoder().encode(text.slice(0, start)).length, byteEnd: new TextEncoder().encode(text.slice(0, start + label.length)).length }, features: [feature] };
}
function html(text: string, facets: AppBskyRichtextFacet.Main[] = []) {
  const record: AppBskyFeedPost.Record = { $type: "app.bsky.feed.post", text, facets, createdAt: "2026-10-10T00:00:00Z" };
  return renderToStaticMarkup(<SocialRichText record={record} />);
}
function documentFor(markup: string) {
  const element = document.createElement("div");
  element.innerHTML = markup;
  return element;
}

describe("Social Markdown", () => {
  it("interprets headings, lists, quotes, emphasis, strong text, and inline code", () => {
    const element = documentFor(html("# Heading\n\n**Bold** and *italic* and `literal *code*`\n\n- First\n- Second\n\n1. One\n2. Two\n\n> Quoted **words**"));
    expect(element.querySelector("h1")?.textContent).toBe("Heading");
    expect(element.querySelector("strong")?.textContent).toBe("Bold");
    expect(element.querySelector("em")?.textContent).toBe("italic");
    expect(element.querySelector("code")?.textContent).toBe("literal *code*");
    expect(element.querySelectorAll("ul li").length).toBe(2);
    expect(element.querySelectorAll("ol li").length).toBe(2);
    expect(element.querySelector("blockquote strong")?.textContent).toBe("words");
  });
  it("preserves UTF-8 native facets inside formatting after emoji and multilingual text", () => {
    const text = "🌎 日本語 **visit** *alice* #news\nNext line";
    const element = documentFor(html(text, [facet(text, "visit", { $type: "app.bsky.richtext.facet#link", uri: "https://example.com/article" }), facet(text, "alice", { $type: "app.bsky.richtext.facet#mention", did: "did:plc:alice" }), facet(text, "#news", { $type: "app.bsky.richtext.facet#tag", tag: "news" })]));
    expect(element.querySelector("strong a")?.textContent).toBe("visit");
    expect(element.querySelector("em a")?.getAttribute("href")).toBe("https://bsky.app/profile/did%3Aplc%3Aalice");
    expect(element.querySelectorAll("a")[2].getAttribute("href")).toBe("https://bsky.app/search?q=%23news");
    expect(element.textContent).toContain("🌎 日本語 visit alice #news\nNext line");
    expect(element.querySelector("p")?.className).toContain("whitespace-pre-wrap");
  });
  it("renders nested strong and emphasis without dropping delimiter characters", () => {
    const element = documentFor(html("***both*** **bold *italic*** *italic **bold*** __bold _italic___"));
    expect(element.querySelector("strong em")?.textContent).toBe("both");
    expect(element.querySelectorAll("strong em")[1].textContent).toBe("italic");
    expect(element.querySelector("em strong")?.textContent).toBe("bold");
    expect(element.textContent).toBe("both bold italic italic bold bold italic");
  });
  it("keeps facet offsets in heading, list and quote blocks", () => {
    const text = "## 🌎 heading\n\n- list\n\n> quote";
    const element = documentFor(html(text, ["heading", "list", "quote"].map(label => facet(text, label, { $type: "app.bsky.richtext.facet#link", uri: `https://example.com/${label}` }))));
    expect(element.querySelector("h2 a")?.textContent).toBe("heading");
    expect(element.querySelector("li a")?.textContent).toBe("list");
    expect(element.querySelector("blockquote a")?.textContent).toBe("quote");
  });
  it("never links or interprets formatting inside inline and fenced code", () => {
    const text = "`alice`\n\n```js\n<script>alice</script> **bold**\n```\n\n~~~\nhttps://example.com\n~~~";
    const first = facet(text, "alice", { $type: "app.bsky.richtext.facet#mention", did: "did:plc:alice" });
    const secondStart = new TextEncoder().encode(text.slice(0, text.lastIndexOf("alice"))).length;
    const element = documentFor(html(text, [first, { ...first, index: { byteStart: secondStart, byteEnd: secondStart + 5 } }]));
    expect(element.querySelectorAll("pre").length).toBe(2);
    expect(element.querySelector("pre code")?.textContent).toBe("<script>alice</script> **bold**");
    expect(element.querySelector("a")).toBeNull();
    expect(element.querySelector("script")).toBeNull();
    expect(element.querySelector("strong")).toBeNull();
  });
  it("supports formatted Markdown links without nested native anchors", () => {
    const text = "[**alice**](https://example.com/path_(one))";
    const element = documentFor(html(text, [facet(text, "alice", { $type: "app.bsky.richtext.facet#mention", did: "did:plc:alice" })]));
    expect(element.querySelectorAll("a").length).toBe(1);
    expect(element.querySelector("a")?.getAttribute("href")).toBe("https://example.com/path_(one)");
    expect(element.querySelector("a strong")?.textContent).toBe("alice");
    expect(element.querySelector("a")?.getAttribute("rel")).toBe("noopener noreferrer");
    expect(element.querySelector("a a")).toBeNull();
  });
  it("escapes raw HTML and blocks unsafe links from both sources", () => {
    for (const uri of ["javascript:alert(1)", "data:text/html,test", "http://example.com", "https://user:password@example.com", "//example.com"]) {
      const text = `<img src=x onerror=alert(1)> [click](${uri}) native`;
      const markup = html(text, [facet(text, "native", { $type: "app.bsky.richtext.facet#link", uri })]);
      const element = documentFor(markup);
      expect(element.querySelector("img")).toBeNull();
      expect(element.querySelector("a")).toBeNull();
      expect(element.textContent).toContain("click");
      expect(markup).toContain("&lt;img");
    }
  });
  it("keeps Markdown images inert and native faceted text literal", () => {
    const text = "![tracking](https://example.com/pixel) file_name_here";
    const element = documentFor(html(text, [facet(text, "file_name_here", { $type: "app.bsky.richtext.facet#link", uri: "https://example.com" })]));
    expect(element.querySelector("img")).toBeNull();
    expect(element.querySelectorAll("a").length).toBe(1);
    expect(element.querySelector("a")?.textContent).toBe("file_name_here");
    expect(element.textContent).toContain("![tracking](https://example.com/pixel)");
  });
  it("keeps plain lines, escapes, incomplete syntax, paragraphs and unfinished fences", () => {
    expect(documentFor(html("line one\nline two\n\nlast line")).querySelectorAll("p").length).toBe(2);
    expect(documentFor(html("\\*literal\\* file_name_here **unfinished [link")).textContent).toBe("*literal* file_name_here **unfinished [link");
    expect(documentFor(html("```\nunfinished <html>")).querySelector("pre code")?.textContent).toBe("unfinished <html>");
    expect(socialMarkdownBlocks("")).toEqual([]);
    expect(socialMarkdownInline("** x **")[0].kind).toBe("text");
  });
});
