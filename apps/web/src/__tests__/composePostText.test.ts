import { expect, it } from "bun:test";
import { compilePostText } from "@/lib/composePostText";
import { postTextLength } from "@/lib/blueskyComposeClient";
import { composeLinkUrl } from "@/lib/blueskyExternalEmbed";

it("turns Markdown hypertext into native UTF-8 facets on labels", () => {
  const { text, facets } = compilePostText("🌎 [**XBOX Labs**](labs.xbox.com) and [café](https://example.com/a_(b)) #news");
  expect(text).toBe("🌎 **XBOX Labs** and café #news");
  expect(facets).toEqual([
    { index: { byteStart: 5, byteEnd: 18 }, features: [{ $type: "app.bsky.richtext.facet#link", uri: "https://labs.xbox.com/" }] },
    { index: { byteStart: 23, byteEnd: 28 }, features: [{ $type: "app.bsky.richtext.facet#link", uri: "https://example.com/a_(b)" }] },
    { index: { byteStart: 29, byteEnd: 34 }, features: [{ $type: "app.bsky.richtext.facet#tag", tag: "news" }] },
  ]);
  expect(composeLinkUrl("[XBOX Labs](labs.xbox.com)")).toBe("https://labs.xbox.com/");
});

it("preserves paragraph whitespace and readable block structure", () => {
  expect(compilePostText("## Heading\n\n- **One**\n- *Two*\n\n> A [link](https://example.com)\n\n```js\nconst x = 1;\n```\nEnd").text)
    .toBe("## Heading\n\n- **One**\n- *Two*\n\n> A link\n\n```js\nconst x = 1;\n```\nEnd");
  expect(compilePostText("  plain text\n\n").text).toBe("  plain text\n\n");
});

it("protects code, unsafe links, and explicit labels from automatic facets", () => {
  const compiled = compilePostText("`@alice.test https://code.test #code` [@bob.test](https://target.test) [bad](javascript:alert(1))");
  expect(compiled.text).toBe("`@alice.test https://code.test #code` @bob.test [bad](javascript:alert(1))");
  expect(compiled.facets).toHaveLength(1);
  expect(compiled.detectionText.trim()).toBe("");
  expect(compilePostText(String.raw`\[label](https://example.com)`).text).toBe(String.raw`\[label](https://example.com)`);
  expect(compilePostText("[unfinished](https://example.com").text).toBe("[unfinished](https://example.com");
  expect(compilePostText("[empty]() [credentials](https://user:pass@example.com)").facets).toEqual([]);
});

it("counts published text without converted hyperlink destinations", () => {
  expect(postTextLength(`[${"é".repeat(300)}](https://example.com/${"x".repeat(500)})`)).toEqual({ graphemes: 300, bytes: 600 });
  expect(compilePostText("[](https://example.com)").text).toBe("");
});

it("preserves literal URL punctuation instead of treating it as emphasis", () => {
  const text = "https://example.com/a*b*c https://example.com/a_b_c";
  expect(compilePostText(text).text).toBe(text);
  expect(compilePostText(text).facets).toHaveLength(2);
});


it.each([
  "**Bold** *Italic* __Strong__ _Emphasis_ ***Both***",
  "# Heading\n## Smaller\n\n> Quote\n- **One**\n1. *Two*",
  "  leading  \r\n\r\ntrailing\t\n",
  String.raw`\*literal\* \_literal\_ \[label](https://example.com)`,
  "```md\n[Literal](https://example.com) **code**\n```\n",
  "~~~\n[Literal](https://example.com)\n~~~",
  "`[Literal](https://example.com)` and ``**literal**``",
  "**unfinished [unfinished](https://example.com",
])("preserves non-hyperlink Markdown exactly: %s", source => {
  expect(compilePostText(source).text).toBe(source);
});

it("converts links inside formatting without removing the surrounding Markdown", () => {
  const compiled = compilePostText("## **[café](https://example.com)**\n\n- *[News](news.example)*\n\n> [Read](https://read.example)\n");
  expect(compiled.text).toBe("## **café**\n\n- *News*\n\n> Read\n");
  const bytes = new TextEncoder().encode(compiled.text);
  expect(compiled.facets.map(facet => new TextDecoder().decode(bytes.slice(facet.index.byteStart, facet.index.byteEnd)))).toEqual(["café", "News", "Read"]);
});

it("keeps unsafe link source literal and unfaceted", () => {
  for (const source of ["[Bad](javascript:alert(1))", "[Credentials](https://user:pass@example.com)", "[Empty]()"]) {
    expect(compilePostText(source).text).toBe(source);
    expect(compilePostText(source).facets).toEqual([]);
    expect(composeLinkUrl(source)).toBeUndefined();
  }
});

it("keeps code literal and unfaceted while converting an adjacent link", () => {
  const source = "```md\n[Code](https://code.example) @code.test #code\n```\n`[Inline](https://inline.example)` [Read](https://read.example)";
  const compiled = compilePostText(source);
  expect(compiled.text).toBe(source.replace("[Read](https://read.example)", "Read"));
  expect(compiled.facets).toHaveLength(1);
  expect(compiled.facets[0].features).toEqual([{ $type: "app.bsky.richtext.facet#link", uri: "https://read.example/" }]);
});

it("counts retained Markdown markers toward the native limits", () => {
  expect(postTextLength(`**${"é".repeat(296)}**`)).toEqual({ graphemes: 300, bytes: 596 });
  expect(postTextLength(`**${"é".repeat(300)}**`)).toEqual({ graphemes: 304, bytes: 604 });
});
