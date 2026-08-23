import { describe, expect, it } from "bun:test";

import { readFeedHeaderClassName } from "@/app/read/ReadArticleFilterBar";

describe("readFeedHeaderClassName", () => {
  it("adds breathing room only to The Wire header", () => {
    expect(readFeedHeaderClassName(true)).toBe("pt-3");
    expect(readFeedHeaderClassName(false)).toBeUndefined();
  });
});
