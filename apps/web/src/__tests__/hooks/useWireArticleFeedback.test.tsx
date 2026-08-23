import { beforeEach, describe, expect, it, mock } from "bun:test";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";

const listFeedback = mock(async () => [] as Array<{
  uri: string;
  cid: string;
  value: {
    $type: "app.thesocialwire.wireFeedback";
    canonicalUrl: string;
    value: "good" | "not_good";
    createdAt: string;
    updatedAt: string;
  };
}>);
const putFeedback = mock(async () => ({ uri: "at://feedback", cid: "cid" }));
const deleteFeedback = mock(async () => undefined);

mock.module("@/hooks/usePDSClient", () => ({
  usePDSClient: () => ({
    listWireArticleFeedback: listFeedback,
    putWireArticleFeedback: putFeedback,
    deleteWireArticleFeedback: deleteFeedback,
  }),
}));

function wrapper({ children }: { children: ReactNode }) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

describe("useWireArticleFeedback", () => {
  beforeEach(() => {
    listFeedback.mockClear();
    putFeedback.mockClear();
    deleteFeedback.mockClear();
    listFeedback.mockResolvedValue([]);
  });

  it("writes a good-article assessment for the canonical URL", async () => {
    const { useWireArticleFeedback } = await import(
      "@/hooks/useWireArticleFeedback"
    );
    const { result } = renderHook(
      () =>
        useWireArticleFeedback(
          "https://example.com/story#comments",
          "at://did:plc:author/app.bsky.feed.post/story",
        ),
      { wrapper },
    );
    await waitFor(() => expect(result.current.isLoading).toBe(false));
    await act(async () => result.current.mutation.mutateAsync("good"));
    expect(putFeedback).toHaveBeenCalledWith({
      canonicalUrl: "https://example.com/story",
      subject: "at://did:plc:author/app.bsky.feed.post/story",
      value: "good",
      createdAt: undefined,
    });
  });

  it("removes the current value when the same choice is selected again", async () => {
    const canonicalUrl = "https://example.com/story";
    listFeedback.mockResolvedValue([
      {
        uri: "at://did:plc:viewer/app.thesocialwire.wireFeedback/key",
        cid: "cid",
        value: {
          $type: "app.thesocialwire.wireFeedback",
          canonicalUrl,
          value: "not_good",
          createdAt: "2026-08-22T00:00:00Z",
          updatedAt: "2026-08-22T00:00:00Z",
        },
      },
    ]);
    const { useWireArticleFeedback } = await import(
      "@/hooks/useWireArticleFeedback"
    );
    const { result } = renderHook(() => useWireArticleFeedback(canonicalUrl), {
      wrapper,
    });
    await waitFor(() => expect(result.current.value).toBe("not_good"));
    await act(async () => result.current.mutation.mutateAsync("not_good"));
    expect(deleteFeedback).toHaveBeenCalledWith(canonicalUrl);
  });
});
