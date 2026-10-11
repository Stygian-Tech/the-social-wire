import { afterEach, describe, expect, it } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import { SocialChatRichText } from "@/components/Social/SocialChatRichText";
import { chatPostReference } from "@/components/Social/SocialChatPostPreview";
afterEach(cleanup);
describe("chat rich text", () => {
  it("preserves UTF-8 facets and links plain HTTPS without rendering HTML or unsafe destinations", () => {
    const prefix = "😀 ";
    const label = "Website";
    render(<SocialChatRichText message={{ text: `${prefix}${label} https://safe.test/path. <img src=x>`, facets: [{ index: { byteStart: new TextEncoder().encode(prefix).length, byteEnd: new TextEncoder().encode(prefix + label).length }, features: [{ $type: "app.bsky.richtext.facet#link", uri: "https://example.test/" }] }] }} />);
    expect(screen.getByRole("link", { name: label }).getAttribute("href")).toBe("https://example.test/");
    expect(screen.getByRole("link", { name: "https://safe.test/path" }).getAttribute("href")).toBe("https://safe.test/path");
    expect(document.querySelector("img") === null).toBe(true);
    cleanup();
    render(<SocialChatRichText message={{ text: label, facets: [{ index: { byteStart: 0, byteEnd: label.length }, features: [{ $type: "app.bsky.richtext.facet#link", uri: "javascript:alert(1)" }] }] }} />);
    expect(screen.queryByRole("link") === null).toBe(true);
    expect(screen.getByText(label)).toBeTruthy();
  });
  it("recognizes only canonical Bluesky post links for bounded previews", () => {
    expect(chatPostReference("https://bsky.app/profile/did%3Aplc%3Aother/post/one")).toEqual({ actor: "did:plc:other", rkey: "one" });
    expect(chatPostReference("https://bsky.app/profile/other.test/post/one")).toEqual({ actor: "other.test", rkey: "one" });
    for (const value of ["https://bsky.app@evil.test/profile/other.test/post/one", "https://bsky.app/profile/other.test/post/one?track=x", "https://bsky.app/profile/other.test/post/%2Funsafe", "https://evil.test/profile/other.test/post/one"]) expect(chatPostReference(value)).toBeUndefined();
  });
});
