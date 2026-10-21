import type { QueryClient } from "@tanstack/react-query";

/** Keep the reading timeline intact; post actions must not fetch a newer feed head. */
export async function invalidateSocialPostQueries(cache: QueryClient, did: string, surfaces: ReadonlySet<string>) {
  const predicate = ({ queryKey }: { queryKey: readonly unknown[] }) => queryKey[0] === "blueskySocial"
    && queryKey[1] === did && surfaces.has(String(queryKey[2]));
  await Promise.all([
    cache.invalidateQueries({ predicate, refetchType: "none" }),
    cache.refetchQueries({ predicate: query => predicate(query) && query.queryKey[2] !== "timeline", type: "active" }),
  ]);
}
