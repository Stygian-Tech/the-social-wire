import { describe, expect, it } from "bun:test";

import {
  ARTICLE_LIST_FILTER_STORAGE_KEY,
  loadArticleListFilter,
  saveArticleListFilter,
} from "@/lib/articleListFilterStorage";

describe("articleListFilterStorage", () => {
  it("defaults to all when unset", () => {
    const storage = {
      store: {} as Record<string, string>,
      getItem(key: string) {
        return this.store[key] ?? null;
      },
      setItem(key: string, value: string) {
        this.store[key] = value;
      },
    };

    expect(loadArticleListFilter(storage)).toBe("all");
  });

  it("persists unread filter choice", () => {
    const storage = {
      store: {} as Record<string, string>,
      getItem(key: string) {
        return this.store[key] ?? null;
      },
      setItem(key: string, value: string) {
        this.store[key] = value;
      },
    };

    saveArticleListFilter(storage, "unread");
    expect(storage.store[ARTICLE_LIST_FILTER_STORAGE_KEY]).toBe("unread");
    expect(loadArticleListFilter(storage)).toBe("unread");
  });
});
