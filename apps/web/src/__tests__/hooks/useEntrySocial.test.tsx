import { describe, expect, it, mock, beforeEach, afterEach } from "bun:test";
import { renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";
import { useEntrySocial } from "@/hooks/useEntrySocial";
import type { EntryDetail } from "@/lib/atprotoClient";

const postMock = mock(async (record: unknown) => ({
  record,
  uri: "at://did:plc:me/app.bsky.feed.post/1",
}));
const likeMock = mock(async (uri: string, cid: string) => {
  void uri;
  void cid;
});
const uploadBlobMock = mock(async (blob: Blob) => ({
  data: {
    blob: {
      $type: "blob",
      ref: { $link: "bafkreithumb" },
      mimeType: blob.type,
      size: blob.size,
    },
  },
}));
const getPostsMock = mock(async () => ({ data: { posts: [] } }));
const getTokenInfoMock = mock(async () => ({
  scope: "atproto",
  iss: "https://pds.example",
  aud: "https://pds.example",
  sub: "did:plc:me",
}));

mock.module("@/hooks/useAuth", () => ({
  useAuth: () => ({
    session: { did: "did:plc:me" },
    isLoading: false,
    oauthSessionReloadSeq: 0,
    applyOAuthSession: () => {},
    getOAuthSession: () => ({
      getTokenInfo: getTokenInfoMock,
      fetchHandler: mock(async () => new Response("{}")),
    }),
    getAuthFetch: () => null,
    reconcileOAuthSession: async () => false,
    signIn: async () => {},
    signOut: async () => {},
  }),
}));

mock.module("@/lib/atprotoClient", () => ({
  createOAuthAgent: () => ({
    post: postMock,
    uploadBlob: uploadBlobMock,
    like: likeMock,
    deleteLike: mock(async () => undefined),
    repost: mock(async () => undefined),
    deleteRepost: mock(async () => undefined),
  }),
  createPublicAppViewAgent: () => ({
    api: {
      app: {
        bsky: {
          feed: {
            getPosts: getPostsMock,
          },
        },
      },
    },
  }),
}));

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: {
      mutations: { retry: false },
      queries: { retry: false },
    },
  });

  return function Wrapper({ children }: { children: React.ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    );
  };
}

const entry: EntryDetail = {
  entryId: "at://did:plc:author/site.standard.document/post1",
  title: "A good article",
  summary: "A useful summary from the publisher.",
  publishedAt: "2026-06-22T00:00:00.000Z",
  contentHtml: "",
  originalUrl: "https://example.com/a-good-article",
};

describe("useEntrySocial", () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    postMock.mockClear();
    likeMock.mockClear();
    uploadBlobMock.mockClear();
    getPostsMock.mockClear();
    getTokenInfoMock.mockClear();
    globalThis.fetch = originalFetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("creates a full link post when the OAuth grant includes Bluesky post access", async () => {
    getTokenInfoMock.mockResolvedValueOnce({
      scope:
        "atproto include:app.bsky.authCreatePosts?aud=did:web:api.bsky.app%23bsky_appview",
      iss: "https://pds.example",
      aud: "https://pds.example",
      sub: "did:plc:me",
    });

    const { result } = renderHook(() => useEntrySocial(entry), {
      wrapper: makeWrapper(),
    });

    await result.current.postMutation.mutateAsync("Worth reading");

    expect(postMock).toHaveBeenCalledTimes(1);
    const postedRecord = postMock.mock.calls[0]?.[0] as unknown;
    expect(postedRecord).toMatchObject({
      text: "Worth reading",
      embed: {
        $type: "app.bsky.embed.external",
        external: {
          uri: "https://example.com/a-good-article",
          title: "A good article",
          description: "A useful summary from the publisher.",
          associatedRecord:
            "at://did:plc:author/site.standard.document/post1",
        },
      },
    });
  });

  it("uploads an external card thumbnail when the image is fetchable", async () => {
    getTokenInfoMock.mockResolvedValueOnce({
      scope:
        "atproto repo:app.bsky.feed.post?action=create&action=delete",
      iss: "https://pds.example",
      aud: "https://pds.example",
      sub: "did:plc:me",
    });
    const fetchMock = mock(async (url: string) => {
      expect(url).toBe(
        "/api/bluesky-card-thumb?url=https%3A%2F%2Fcdn.example%2Fthumb.png"
      );
      return new Response(new Blob(["thumb"], { type: "image/png" }));
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const { result } = renderHook(
      () =>
        useEntrySocial({
          ...entry,
          thumbnailUrl: "https://cdn.example/thumb.png",
        }),
      {
        wrapper: makeWrapper(),
      }
    );

    await result.current.postMutation.mutateAsync("Worth reading");

    expect(uploadBlobMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const postedRecord = postMock.mock.calls[0]?.[0] as unknown;
    expect(postedRecord).toMatchObject({
      embed: {
        external: {
          thumb: {
            ref: { $link: "bafkreithumb" },
            mimeType: "image/png",
          },
        },
      },
    });
  });

  it("accepts an expanded aggregate repo permission set for Bluesky post access", async () => {
    getTokenInfoMock.mockResolvedValueOnce({
      scope:
        "atproto repo?collection=app.bsky.feed.post&collection=app.bsky.feed.like&action=create",
      iss: "https://pds.example",
      aud: "https://pds.example",
      sub: "did:plc:me",
    });

    const { result } = renderHook(() => useEntrySocial(entry), {
      wrapper: makeWrapper(),
    });

    await result.current.postMutation.mutateAsync("Worth reading");

    expect(postMock).toHaveBeenCalledTimes(1);
  });

  it("fails before writing when the OAuth grant is missing Bluesky post access", async () => {
    getTokenInfoMock.mockResolvedValueOnce({
      scope: "atproto repo:app.thesocialwire.folder?action=create",
      iss: "https://pds.example",
      aud: "https://pds.example",
      sub: "did:plc:me",
    });

    const { result } = renderHook(() => useEntrySocial(entry), {
      wrapper: makeWrapper(),
    });

    await expect(
      result.current.postMutation.mutateAsync("Worth reading")
    ).rejects.toThrow("posting permission needs to be refreshed");
    expect(postMock).not.toHaveBeenCalled();
  });

  it("checks like create access before creating a Bluesky like", async () => {
    getTokenInfoMock.mockResolvedValueOnce({
      scope:
        "atproto repo:app.bsky.feed.like?action=create&action=delete",
      iss: "https://pds.example",
      aud: "https://pds.example",
      sub: "did:plc:me",
    });

    const linkedEntry: EntryDetail = {
      ...entry,
      bskyPostUri: "at://did:plc:author/app.bsky.feed.post/root",
      bskyPostCid: "bafyreigood",
    };
    const { result } = renderHook(() => useEntrySocial(linkedEntry), {
      wrapper: makeWrapper(),
    });

    await result.current.toggleLikeMutation.mutateAsync({});

    expect(likeMock).toHaveBeenCalledWith(
      "at://did:plc:author/app.bsky.feed.post/root",
      "bafyreigood"
    );
  });

  it("uses the full link embed and likes an unliked linked post while posting", async () => {
    getTokenInfoMock.mockResolvedValue({
      scope:
        "atproto include:app.bsky.authCreatePosts?aud=did:web:api.bsky.app%23bsky_appview repo:app.bsky.feed.like?action=create",
      iss: "https://pds.example",
      aud: "https://pds.example",
      sub: "did:plc:me",
    });

    const linkedEntry: EntryDetail = {
      ...entry,
      bskyPostUri: "at://did:plc:author/app.bsky.feed.post/root",
      bskyPostCid: "bafyreigood",
    };
    const { result } = renderHook(() => useEntrySocial(linkedEntry), {
      wrapper: makeWrapper(),
    });

    await result.current.postMutation.mutateAsync("Worth reading");

    expect(postMock.mock.calls[0]?.[0]).toMatchObject({
      text: "Worth reading",
      embed: {
        $type: "app.bsky.embed.external",
        external: {
          uri: "https://example.com/a-good-article",
          title: "A good article",
          description: "A useful summary from the publisher.",
        },
      },
    });
    expect(likeMock).toHaveBeenCalledWith(
      linkedEntry.bskyPostUri,
      linkedEntry.bskyPostCid
    );
  });
});
