"use client";

import { useQuery } from "@tanstack/react-query";
import { getFinanceCatalog } from "@/lib/financeFeedClient";

/** Share server rollout confirmation between navigation and the Finance reader. */
export function useFinanceCatalog({ enabled = true }: { enabled?: boolean } = {}) {
  return useQuery({ queryKey: ["financeCatalog"], enabled, queryFn: ({ signal }) => getFinanceCatalog(signal), staleTime: 5 * 60000 });
}
