import type { InfiniteData, QueryClient } from "@tanstack/react-query";
import { invalidateSocialPostQueries } from "./invalidateSocialPostQueries";

const POST_SURFACES = new Set(["thread", "timeline", "profileTimeline", "explore", "bookmarks", "notifications"]);
const PAGINATED_POST_SURFACES = new Set(["profileTimeline", "explore", "bookmarks", "notifications"]);

/** Refresh newest rows, then allow two bounded retries for PDS-to-AppView indexing. */
export function refreshSocialPostQueries(
  cache: QueryClient,
  viewerDid: string,
  isCurrentViewer: () => boolean,
): () => void {
  let cancelled = false;
  const timers: ReturnType<typeof setTimeout>[] = [];
  const current = () => !cancelled && isCurrentViewer();
  const predicate = ({ queryKey }: { queryKey: readonly unknown[] }) => queryKey[0] === "blueskySocial"
    && queryKey[1] === viewerDid && POST_SURFACES.has(String(queryKey[2]));

  async function refresh(resetPages: boolean) {
    if (!current()) return;
    // Let initial loads and pagination finish; timeline membership is not refetched below.
    await cache.cancelQueries({ predicate: query => predicate(query) && query.queryKey[2] !== "timeline" });
    if (!current()) return;
    if (resetPages) {
      cache.setQueriesData<InfiniteData<unknown>>({ predicate: query => predicate(query)
        && PAGINATED_POST_SURFACES.has(String(query.queryKey[2])) }, data => {
        if (!data || !Array.isArray(data.pages) || !Array.isArray(data.pageParams) || data.pages.length <= 1) return data;
        return { ...data, pages: data.pages.slice(0, 1), pageParams: data.pageParams.slice(0, 1) };
      });
    }
    await invalidateSocialPostQueries(cache, viewerDid, POST_SURFACES);
  }

  void refresh(true).then(() => {
    if (!current()) return;
    for (const delay of [1_000, 3_000]) {
      timers.push(setTimeout(() => { void refresh(false); }, delay));
    }
  });
  return () => {
    cancelled = true;
    timers.forEach(clearTimeout);
  };
}
