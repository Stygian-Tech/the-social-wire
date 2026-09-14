import type { CircleFeedCatalog } from "@/lib/circleFeedClient";

/** Story availability affects the feed's content, not its navigation entry. */
export function isCircleNavigationEnabled(
  catalog: Pick<CircleFeedCatalog, "enabled"> | undefined,
  showCircle = true,
): boolean {
  return showCircle && catalog?.enabled !== false;
}
