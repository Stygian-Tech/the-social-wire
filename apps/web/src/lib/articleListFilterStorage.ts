import type { ArticleListFilter } from "@/lib/entryArticleFilter";

export const ARTICLE_LIST_FILTER_STORAGE_KEY =
  "the-social-wire.article-list-filter.v1";

export function loadArticleListFilter(
  storage: Pick<Storage, "getItem">
): ArticleListFilter {
  try {
    const raw = storage.getItem(ARTICLE_LIST_FILTER_STORAGE_KEY);
    return raw === "unread" ? "unread" : "all";
  } catch {
    return "all";
  }
}

export function saveArticleListFilter(
  storage: Pick<Storage, "setItem">,
  filter: ArticleListFilter
): void {
  try {
    storage.setItem(ARTICLE_LIST_FILTER_STORAGE_KEY, filter);
  } catch {
    /* quota / private mode */
  }
}
