import type { InfiniteData, Query } from "@tanstack/react-query";

/** Keep only bounded, unexpired Finance generations with the current scoped key. */
export function shouldPersistFinanceQuery(query: Pick<Query, "queryKey" | "state">): boolean {
  const key = query.queryKey;
  if (!Array.isArray(key) || key[0] !== "financeEntries" || key.length !== 8 || query.state.status !== "success") return false;
  const data = query.state.data as InfiniteData<{ items?: unknown[]; expiresAt?: string }> | undefined;
  if (!data?.pages.length || data.pages.length > 3) return false;
  return data.pages.every(page => !!page.expiresAt && Date.parse(page.expiresAt) > Date.now()) && data.pages.reduce((count, page) => count + (page.items?.length ?? 0), 0) <= 150;
}
