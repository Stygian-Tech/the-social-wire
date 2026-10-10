import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render, waitFor } from "@testing-library/react";

import * as Auth from "@/hooks/useAuth";
import { SocialViewerCacheCleanup } from "@/components/Social/SocialViewerCacheCleanup";

const alice = "did:plc:alice";
const bob = "did:plc:bob";
const aliceTimeline = ["blueskySocial", alice, "timeline", 0, "following", ""];
const aliceCatalog = ["blueskySocial", alice, "catalog", 0];
const bobTimeline = ["blueskySocial", bob, "timeline", 0, "following", ""];
let viewerDid: string | undefined;
let queryClient: QueryClient;
let restoreAuth: () => void;

function view() {
  return <QueryClientProvider client={queryClient}><SocialViewerCacheCleanup /></QueryClientProvider>;
}

beforeEach(() => {
  viewerDid = alice;
  queryClient = new QueryClient();
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: viewerDid ? { did: viewerDid } : null } as ReturnType<typeof Auth.useAuth>));
  restoreAuth = () => auth.mockRestore();
  queryClient.setQueryData(aliceTimeline, { pages: [{ feed: ["Alice post"] }] });
  queryClient.setQueryData(aliceCatalog, { feeds: ["Alice feed"], moderation: { userDid: alice } });
  queryClient.setQueryData(bobTimeline, { pages: [{ feed: ["Bob post"] }] });
  queryClient.setQueryData(["wireEdition"], { stories: ["Public story"] });
});
afterEach(() => {
  cleanup();
  queryClient.clear();
  restoreAuth();
});

describe("Social viewer cache cleanup", () => {
  it("preserves the current viewer's data on mount and ordinary rerenders", () => {
    const { rerender } = render(view());
    rerender(view());
    expect(queryClient.getQueryData(aliceTimeline)).toBeDefined();
    expect(queryClient.getQueryData(aliceCatalog)).toBeDefined();
  });

  it("removes previous viewer timelines and moderation settings on account switch and logout", () => {
    const { rerender } = render(view());
    viewerDid = bob;
    rerender(view());
    expect(queryClient.getQueryData(aliceTimeline)).toBeUndefined();
    expect(queryClient.getQueryData(aliceCatalog)).toBeUndefined();
    expect(queryClient.getQueryData(bobTimeline)).toBeDefined();
    viewerDid = undefined;
    rerender(view());
    expect(queryClient.getQueryData(bobTimeline)).toBeUndefined();
    expect(queryClient.getQueryData(["wireEdition"])).toBeDefined();
  });

  it("cancels in-flight old-viewer requests before logout removes their cache", async () => {
    const { rerender } = render(view());
    let requestSignal: AbortSignal | undefined;
    const pendingKey = ["blueskySocial", alice, "timeline", 0, "feed", "at://did:plc:alice/app.bsky.feed.generator/news"];
    const request = queryClient.fetchQuery({ queryKey: pendingKey, queryFn: ({ signal }) => {
      requestSignal = signal;
      return new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true }));
    } }).catch(() => undefined);
    await waitFor(() => expect(requestSignal).toBeDefined());
    expect(requestSignal?.aborted).toBe(false);
    viewerDid = undefined;
    rerender(view());
    expect(requestSignal?.aborted).toBe(true);
    await request;
    expect(queryClient.getQueryState(pendingKey)).toBeUndefined();
    expect(queryClient.getQueryData(aliceTimeline)).toBeUndefined();
    expect(queryClient.getQueryData(aliceCatalog)).toBeUndefined();
  });

  it("keeps incoming viewer caches when signing in from anonymous state", () => {
    viewerDid = undefined;
    const { rerender } = render(view());
    viewerDid = bob;
    rerender(view());
    expect(queryClient.getQueryData(bobTimeline)).toBeDefined();
  });
});
