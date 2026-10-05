"use client";

import { useQuery } from "@tanstack/react-query";
import { getFinanceCatalog } from "@/lib/financeFeedClient";

/** Share server rollout confirmation between navigation and the Finance reader. */
export function useFinanceCatalog() {
  return useQuery({ queryKey: ["financeCatalog"], queryFn: ({ signal }) => getFinanceCatalog(signal), staleTime: 5 * 60000 });
}
