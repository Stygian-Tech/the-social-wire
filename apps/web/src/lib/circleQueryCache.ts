import type { QueryClient } from "@tanstack/react-query";

export function clearCircleViewerQueries(
  queryClient: QueryClient,
  viewerDid: string,
): void {
  queryClient.removeQueries({ queryKey: ["circleCatalog", viewerDid] });
  queryClient.removeQueries({ queryKey: ["circleEdition", viewerDid] });
  for (const mutation of queryClient.getMutationCache().findAll({
    mutationKey: ["setCircleItemHidden", viewerDid],
  })) {
    queryClient.getMutationCache().remove(mutation);
  }
}
