import { beforeEach, describe, expect, it, mock } from "bun:test";
import {
  QueryClient,
  QueryClientProvider,
} from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";

const listRecommendations = mock(async () => [] as Array<{
  uri: string;
  cid: string;
  value: {
    $type: "site.standard.graph.recommend";
    document: string;
    createdAt: string;
  };
}>);
const createRecommendation = mock(async () => ({
  uri: "at://did:plc:viewer/site.standard.graph.recommend/3abc",
  cid: "cid-created",
}));
const deleteRecommendation = mock(async () => undefined);

mock.module("@/hooks/usePDSClient", () => ({
  usePDSClient: () => ({
    listStandardSiteRecommendations: listRecommendations,
    createStandardSiteRecommendation: createRecommendation,
    deleteStandardSiteRecommendation: deleteRecommendation,
  }),
}));

function wrapper({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false },
      mutations: { retry: false },
    },
  });
  return (
    <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
  );
}

describe("useStandardSiteRecommendation", () => {
  beforeEach(() => {
    listRecommendations.mockClear();
    createRecommendation.mockClear();
    deleteRecommendation.mockClear();
    listRecommendations.mockResolvedValue([]);
  });

  it("creates a recommendation for a standard.site document", async () => {
    const { useStandardSiteRecommendation } = await import(
      "@/hooks/useStandardSiteRecommendation"
    );
    const document =
      "at://did:plc:author/site.standard.document/recommendable";
    const { result } = renderHook(
      () => useStandardSiteRecommendation(document),
      { wrapper }
    );

    await waitFor(() => expect(result.current.isLoading).toBe(false));
    await act(async () => result.current.toggleMutation.mutateAsync());
    await waitFor(() =>
      expect(listRecommendations.mock.calls.length).toBeGreaterThanOrEqual(2)
    );

    expect(createRecommendation).toHaveBeenCalledWith(document);
    expect(deleteRecommendation).not.toHaveBeenCalled();
  });

  it("deletes an existing recommendation", async () => {
    const { useStandardSiteRecommendation } = await import(
      "@/hooks/useStandardSiteRecommendation"
    );
    const document =
      "at://did:plc:author/site.standard.document/recommended";
    const recommendationUri =
      "at://did:plc:viewer/site.standard.graph.recommend/3existing";
    listRecommendations.mockResolvedValue([
      {
        uri: recommendationUri,
        cid: "cid-existing",
        value: {
          $type: "site.standard.graph.recommend",
          document,
          createdAt: "2026-07-29T00:00:00.000Z",
        },
      },
    ]);

    const { result } = renderHook(
      () => useStandardSiteRecommendation(document),
      { wrapper }
    );

    await waitFor(() => expect(result.current.recommended).toBe(true));
    await act(async () => result.current.toggleMutation.mutateAsync());
    await waitFor(() =>
      expect(listRecommendations.mock.calls.length).toBeGreaterThanOrEqual(2)
    );

    expect(deleteRecommendation).toHaveBeenCalledWith(recommendationUri);
    expect(createRecommendation).not.toHaveBeenCalled();
  });

  it("does not query or expose Recommend for other collections", async () => {
    const { useStandardSiteRecommendation } = await import(
      "@/hooks/useStandardSiteRecommendation"
    );
    const { result } = renderHook(
      () =>
        useStandardSiteRecommendation(
          "at://did:plc:author/app.bsky.feed.post/not-applicable"
        ),
      { wrapper }
    );

    expect(result.current.applicable).toBe(false);
    expect(listRecommendations).not.toHaveBeenCalled();
  });
});
