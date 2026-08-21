import { describe, expect, it } from "bun:test";

import {
  isReaderFeedSelection,
  loadReaderFeedSelection,
  READER_FEED_SELECTION_STORAGE_KEY,
  saveReaderFeedSelection,
} from "@/lib/readerFeedSelectionStorage";

describe("reader feed selection storage", () => {
  it("rejects unknown route feed parameters instead of falling through", () => {
    expect(isReaderFeedSelection("wire")).toBe(true);
    expect(isReaderFeedSelection("subscribed")).toBe(true);
    expect(isReaderFeedSelection("following")).toBe(true);
    expect(isReaderFeedSelection("unknown")).toBe(false);
    expect(isReaderFeedSelection(null)).toBe(false);
  });

  it("keeps The Wire choice separate from shared PDS feed preferences", () => {
    const values = new Map<string, string>();
    const storage = {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
    };

    expect(loadReaderFeedSelection(storage)).toBeNull();
    saveReaderFeedSelection(storage, "wire");
    expect(values.get(READER_FEED_SELECTION_STORAGE_KEY)).toBe("wire");
    expect(loadReaderFeedSelection(storage)).toBe("wire");
  });

  it("rejects unknown stored values", () => {
    const storage = { getItem: () => "finance" };
    expect(loadReaderFeedSelection(storage)).toBeNull();
  });

  it("honors the existing remembered publication tab during migration", () => {
    const storage = {
      getItem: (key: string) =>
        key === "the-social-wire.sidebar-publication-tab.v1"
          ? "following"
          : null,
    };
    expect(loadReaderFeedSelection(storage)).toBe("following");
  });
});
