import { expect, it } from "bun:test";
import { compilePostText } from "@/lib/composePostText";
import { postTextLength } from "@/lib/blueskyComposeClient";
import { composeLinkUrl } from "@/lib/blueskyExternalEmbed";

it("turns Markdown hypertext into native UTF-8 facets on labels", () => {
  const { text, facets } = compilePostText("🌎 [**XBOX Labs**](labs.xbox.com) and [café](https://example.com/a_(b)) #news");
  expect(text).toBe("🌎 XBOX Labs and café #news");
  expect(facets).toEqual([
    { index: { byteStart: 5, byteEnd: 14 }, features: [{ $type: "app.bsky.richtext.facet#link", uri: "https://labs.xbox.com/" }] },
    { index: { byteStart: 19, byteEnd: 24 }, features: [{ $type: "app.bsky.richtext.facet#link", uri: "https://example.com/a_(b)" }] },
    { index: { byteStart: 25, byteEnd: 30 }, features: [{ $type: "app.bsky.richtext.facet#tag", tag: "news" }] },
  ]);
  expect(composeLinkUrl("[XBOX Labs](labs.xbox.com)")).toBe("https://labs.xbox.com/");
});

it("preserves paragraph whitespace and readable block structure", () => {
  expect(compilePostText("## Heading\n\n- **One**\n- *Two*\n\n> A [link](https://example.com)\n\n```js\nconst x = 1;\n```\nEnd").text)
    .toBe("Heading\n\n- One\n- Two\n\n> A link\n\nconst x = 1;\nEnd");
  expect(compilePostText("  plain text\n\n").text).toBe("  plain text\n\n");
});

it("protects code, unsafe links, and explicit labels from automatic facets", () => {
  const compiled = compilePostText("`@alice.test https://code.test #code` [@bob.test](https://target.test) [bad](javascript:alert(1))");
  expect(compiled.text).toBe("@alice.test https://code.test #code @bob.test bad");
  expect(compiled.facets).toHaveLength(1);
  expect(compiled.detectionText.trim()).toBe("");
  expect(compilePostText(String.raw`\[label](https://example.com)`).text).toBe("[label](https://example.com)");
  expect(compilePostText("[unfinished](https://example.com").text).toBe("[unfinished](https://example.com");
  expect(compilePostText("[empty]() [credentials](https://user:pass@example.com)").facets).toEqual([]);
});

it("counts published text rather than hidden URLs and Markdown markers", () => {
  expect(postTextLength(`[${"é".repeat(300)}](https://example.com/${"x".repeat(500)})`)).toEqual({ graphemes: 300, bytes: 600 });
  expect(compilePostText("[](https://example.com)").text).toBe("");
});

it("preserves literal URL punctuation instead of treating it as emphasis", () => {
  const text = "https://example.com/a*b*c https://example.com/a_b_c";
  expect(compilePostText(text).text).toBe(text);
  expect(compilePostText(text).facets).toHaveLength(2);
});
