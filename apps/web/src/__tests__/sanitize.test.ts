/**
 * Unit tests for lib/sanitize.ts
 *
 * DOMPurify requires a real DOM; these run under bun:test with jsdom.
 */

import { describe, it, expect } from "bun:test";
import {
  prepareArticleHTML,
  sanitizeHTML,
  sanitizeHTMLWithLinks,
} from "@/lib/sanitize";

describe("sanitizeHTML", () => {
  it("passes through safe HTML unchanged", () => {
    const input = "<p>Hello <strong>world</strong>!</p>";
    const result = sanitizeHTML(input);
    expect(result).toContain("Hello");
    expect(result).toContain("<strong>world</strong>");
  });

  it("strips script tags", () => {
    const input = '<p>Safe</p><script>alert("xss")</script>';
    const result = sanitizeHTML(input);
    expect(result).not.toContain("<script");
    expect(result).not.toContain("alert");
    expect(result).toContain("Safe");
  });

  it("strips onclick and other event handlers", () => {
    const input = '<button onclick="evil()">Click me</button>';
    const result = sanitizeHTML(input);
    expect(result).not.toContain("onclick");
    expect(result).not.toContain("evil");
  });

  it("strips javascript: hrefs", () => {
    const input = '<a href="javascript:alert(1)">Link</a>';
    const result = sanitizeHTML(input);
    expect(result).not.toContain("javascript:");
  });

  it("strips iframes", () => {
    const input = '<iframe src="https://evil.com"></iframe>';
    const result = sanitizeHTML(input);
    expect(result).not.toContain("<iframe");
  });

  it("allows safe anchor tags with https href", () => {
    const input = '<a href="https://example.com">Link</a>';
    const result = sanitizeHTML(input);
    expect(result).toContain("https://example.com");
  });

  it("allows img tags with safe src", () => {
    const input = '<img src="https://example.com/img.png" alt="test" />';
    const result = sanitizeHTML(input);
    expect(result).toContain("https://example.com/img.png");
  });

  it("allows controlled HTTPS audio and video without autoplay", () => {
    const input =
      '<video src="https://example.com/movie.mp4" autoplay></video>' +
      '<audio><source src="https://example.com/audio.mp3"></audio>';
    const result = sanitizeHTML(input);
    expect(result).toContain("<video");
    expect(result).toContain("<audio");
    expect(result).toContain("<source");
    expect(result).toContain("controls");
    expect(result).toContain('preload="metadata"');
    expect(result).not.toContain("autoplay");
  });

  it("upgrades http img src to https (mixed content defense)", () => {
    const input =
      '<img src="http://atproto.brid.gy/xrpc/com.atproto.sync.getBlob?did=x&cid=y" alt="" />';
    const result = sanitizeHTML(input);
    expect(result).toContain("https://atproto.brid.gy/");
    expect(result).not.toContain('src="http://');
  });

  it("normalizes https anchors to strip bridge_completed (sanitization ran only for http before)", () => {
    const input =
      '<a href="https://example.com/article?bridge_completed=1">x</a>';
    const result = sanitizeHTML(input);
    expect(result).toContain('href="https://example.com/article"');
    expect(result).not.toContain("bridge_completed");
  });

  it("strips data: URI images", () => {
    const input = '<img src="data:image/png;base64,abc" />';
    const result = sanitizeHTML(input);
    expect(result).not.toContain("data:");
  });

  it("handles empty string", () => {
    expect(sanitizeHTML("")).toBe("");
  });
});

describe("sanitizeHTMLWithLinks", () => {
  it("adds target=_blank to external links", () => {
    const input = '<a href="https://example.com">Link</a>';
    const result = sanitizeHTMLWithLinks(input);
    expect(result).toContain('target="_blank"');
    expect(result).toContain('rel="noopener noreferrer"');
  });

  it("still sanitizes unsafe content", () => {
    const input = '<script>evil()</script><a href="https://ok.com">ok</a>';
    const result = sanitizeHTMLWithLinks(input);
    expect(result).not.toContain("<script");
    expect(result).toContain("https://ok.com");
  });

  it("normalizes plain text into paragraphs and linkifies bare URLs", () => {
    const result = sanitizeHTMLWithLinks(
      "First line\nsecond line\n\nVisit https://example.com/docs."
    );
    expect(result).toContain("<p>First line<br>second line</p>");
    expect(result).toContain(
      '<a href="https://example.com/docs" target="_blank" rel="noopener noreferrer">https://example.com/docs</a>.'
    );
  });

  it("repairs escaped article markup before sanitizing", () => {
    const result = sanitizeHTMLWithLinks(
      "<p>&lt;h2&gt;Heading&lt;/h2&gt;&lt;p&gt;Body&lt;/p&gt;</p>"
    );
    expect(result).toContain("<h2>Heading</h2>");
    expect(result).toContain("<p>Body</p>");
    expect(result).not.toContain("&lt;h2&gt;");
  });

  it("linkifies www URLs but preserves anchors and code samples", () => {
    const result = sanitizeHTMLWithLinks(
      '<p>www.example.com <a href="https://linked.example">https://linked.example</a></p>' +
        "<pre>https://code.example</pre>"
    );
    expect(result).toContain('<a href="https://www.example.com"');
    expect(result.match(/href="https:\/\/linked\.example"/g)).toHaveLength(1);
    expect(result).toContain("<pre>https://code.example</pre>");
  });

  it("keeps balanced URL parentheses and leaves sentence punctuation outside", () => {
    const result = sanitizeHTMLWithLinks(
      "Read https://example.com/article_(reader), then continue."
    );
    expect(result).toContain(
      'href="https://example.com/article_(reader)"'
    );
    expect(result).toContain("</a>, then continue.");
  });

  it("replaces blocked embeds with safe external links", () => {
    const result = sanitizeHTMLWithLinks(
      '<iframe src="http://video.example/watch/1"></iframe>' +
        '<embed src="javascript:alert(1)">'
    );
    expect(result).not.toContain("<iframe");
    expect(result).not.toContain("<embed");
    expect(result).not.toContain("javascript:");
    expect(result).toContain("Open Embedded Media");
    expect(result).toContain('href="https://video.example/watch/1"');
  });

  it("gracefully normalizes malformed publisher HTML", () => {
    const result = sanitizeHTMLWithLinks(
      "<div><p>Readable <strong>content<script>evil()</script><p>Next"
    );
    expect(result).not.toContain("<script");
    expect(result).not.toContain("evil");
    expect(result).toContain("Readable");
    expect(result).toContain("Next");
  });
});

describe("prepareArticleHTML", () => {
  it("removes duplicate media controls before applying safe defaults", () => {
    const result = prepareArticleHTML(
      '<video controls="controls" preload="auto" autoplay src="https://example.com/v.mp4"></video>'
    );
    expect(result.match(/\bcontrols\b/g)).toHaveLength(1);
    expect(result).toContain('preload="metadata"');
    expect(result).not.toContain("autoplay");
  });
});
