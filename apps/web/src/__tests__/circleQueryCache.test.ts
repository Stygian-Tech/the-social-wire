import { describe, expect, it } from "bun:test";
import { QueryClient } from "@tanstack/react-query";

import { clearCircleViewerQueries } from "@/lib/circleQueryCache";

describe("Your Circle viewer cache", () => {
  it("removes the signed-out viewer's private queries without touching another viewer", () => {
    const queryClient = new QueryClient();
    queryClient.setQueryData(["circleCatalog", "did:plc:alice", 1], {
      available: true,
    });
    queryClient.setQueryData(["circleEdition", "did:plc:alice", "en", 1], {
      pages: [],
    });
    queryClient.setQueryData(["circleEdition", "did:plc:bob", "en", 1], {
      pages: [{ generationId: "bob" }],
    });
    queryClient.getMutationCache().build(queryClient, {
      mutationKey: ["setCircleItemHidden", "did:plc:alice"],
      mutationFn: async () => undefined,
    });
    queryClient.getMutationCache().build(queryClient, {
      mutationKey: ["setCircleItemHidden", "did:plc:bob"],
      mutationFn: async () => undefined,
    });

    clearCircleViewerQueries(queryClient, "did:plc:alice");

    expect(
      queryClient.getQueriesData({
        queryKey: ["circleCatalog", "did:plc:alice"],
      }),
    ).toEqual([]);
    expect(
      queryClient.getQueriesData({
        queryKey: ["circleEdition", "did:plc:alice"],
      }),
    ).toEqual([]);
    expect(
      queryClient.getQueryData([
        "circleEdition",
        "did:plc:bob",
        "en",
        1,
      ]),
    ).toBeDefined();
    expect(
      queryClient.getMutationCache().findAll({
        mutationKey: ["setCircleItemHidden", "did:plc:alice"],
      }),
    ).toEqual([]);
    expect(
      queryClient.getMutationCache().findAll({
        mutationKey: ["setCircleItemHidden", "did:plc:bob"],
      }),
    ).toHaveLength(1);
  });
});
