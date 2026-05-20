import { describe, expect, it } from "bun:test";
import { findReadLaterService } from "@/lib/readLaterServices";

describe("useReadLaterPreferences helpers", () => {
  it("defaults read-later service to latr-link", () => {
    expect(findReadLaterService("latr-link").connected).toBe(true);
  });
});
