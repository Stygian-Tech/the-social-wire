import { describe, expect, it } from "bun:test";

import { shouldShowEditorialFeedLoading } from "@/components/Wire/editorialFeedLoading";

describe("shouldShowEditorialFeedLoading", () => {
  it("keeps a persisted empty edition in loading state while it refreshes", () => {
    expect(shouldShowEditorialFeedLoading(0, false, false, true)).toBe(true);
  });

  it("shows a settled empty state after loading and refresh finish", () => {
    expect(shouldShowEditorialFeedLoading(0, false, false, false)).toBe(false);
  });

  it("keeps cached stories visible during a background refresh", () => {
    expect(shouldShowEditorialFeedLoading(50, false, false, true)).toBe(false);
  });
});
