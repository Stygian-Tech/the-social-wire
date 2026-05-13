/**
 * Unit tests for lib/sanitize.ts
 *
 * DOMPurify requires a real DOM; these run under bun:test with jsdom.
 */

import { describe, it, expect } from "bun:test";
import { sanitizeHTML, sanitizeHTMLWithLinks } from "@/lib/sanitize";

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

  it("upgrades http img src to https (mixed content defense)", () => {
    const input =
      '<img src="http://atproto.brid.gy/xrpc/com.atproto.sync.getBlob?did=x&cid=y" alt="" />';
    const result = sanitizeHTML(input);
    expect(result).toContain("https://atproto.brid.gy/");
    expect(result).not.toContain('src="http://');
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
});
