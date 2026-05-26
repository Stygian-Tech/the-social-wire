import { describe, expect, it } from "bun:test";
import {
  isSubstantialArticleBody,
  resolveEntryArticlePresentation,
  lockedEntryArticlePresentation,
  clearLockedEntryArticlePresentationsForTests,
} from "@/lib/entryArticlePresentation";

describe("entryArticlePresentation", () => {
  it("treats short RSS summaries as non-substantial", () => {
    expect(isSubstantialArticleBody("<p>Short summary.</p>")).toBe(false);
  });

  it("treats long article HTML as substantial", () => {
    const long = `<p>${"word ".repeat(80)}</p>`;
    expect(isSubstantialArticleBody(long)).toBe(true);
  });

  it("prefers iframe when only a short summary exists", () => {
    expect(
      resolveEntryArticlePresentation({
        contentHtml: "<p>Short summary.</p>",
        originalUrl: "https://example.com/article",
      })
    ).toBe("embed");
  });

  it("prefers record HTML for substantial bodies", () => {
    const long = `<p>${"word ".repeat(80)}</p>`;
    expect(
      resolveEntryArticlePresentation({
        contentHtml: long,
        originalUrl: "https://example.com/article",
      })
    ).toBe("html");
  });

  it("locks presentation per entry id across later inputs", () => {
    clearLockedEntryArticlePresentationsForTests();
    const entryId = "at://did:plc:alice/site.standard.document/entry1";
    expect(
      lockedEntryArticlePresentation(entryId, {
        contentHtml: "<p>Short summary.</p>",
        originalUrl: "https://example.com/article",
      })
    ).toBe("embed");
    const long = `<p>${"word ".repeat(80)}</p>`;
    expect(
      lockedEntryArticlePresentation(entryId, {
        contentHtml: long,
        originalUrl: "https://example.com/article",
      })
    ).toBe("embed");
  });
});
