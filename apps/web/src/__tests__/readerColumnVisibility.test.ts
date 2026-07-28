import { describe, expect, it } from "bun:test";

import { shouldShowArticleListColumn } from "@/lib/readerColumnVisibility";

describe("readerColumnVisibility", () => {
  it("follows the user preference in portrait tablet layouts", () => {
    expect(
      shouldShowArticleListColumn({
        isTabletPortrait: true,
        isOpenInTabletPortrait: false,
      })
    ).toBe(false);
    expect(
      shouldShowArticleListColumn({
        isTabletPortrait: true,
        isOpenInTabletPortrait: true,
      })
    ).toBe(true);
  });

  it("keeps the article list visible outside portrait tablet layouts", () => {
    expect(
      shouldShowArticleListColumn({
        isTabletPortrait: false,
        isOpenInTabletPortrait: false,
      })
    ).toBe(true);
  });
});
