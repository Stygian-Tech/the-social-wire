import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, render } from "@testing-library/react";

import * as AuthHook from "@/hooks/useAuth";
import { CircleViewerCacheCleanup } from "@/components/Circle/CircleViewerCacheCleanup";

describe("Circle viewer cache cleanup lifecycle", () => {
  let queryClient: QueryClient;
  let auth: ReturnType<typeof spyOn<typeof AuthHook, "useAuth">>;
  let viewerDID: string | undefined;
  const aliceKey = ["circleEdition", "did:plc:alice", "en"];
  const bobKey = ["circleEdition", "did:plc:bob", "en"];

  function view() {
    return <QueryClientProvider client={queryClient}><CircleViewerCacheCleanup /></QueryClientProvider>;
  }

  beforeEach(() => {
    queryClient = new QueryClient();
    viewerDID = "did:plc:alice";
    auth = spyOn(AuthHook, "useAuth").mockImplementation(() => ({
      session: viewerDID ? { did: viewerDID } : null,
    } as ReturnType<typeof AuthHook.useAuth>));
    queryClient.setQueryData(aliceKey, { stories: ["Alice private story"] });
    queryClient.setQueryData(bobKey, { stories: ["Bob private story"] });
    queryClient.setQueryData(["wireEdition"], { stories: ["Public story"] });
  });

  afterEach(() => {
    cleanup();
    queryClient.clear();
    auth.mockRestore();
  });

  it("preserves the current viewer cache on initial mount and ordinary renders", () => {
    const { rerender } = render(view());
    rerender(view());
    expect(queryClient.getQueryData(aliceKey)).toBeDefined();
  });

  it("removes the previous viewer's cache on account switch, then clears the new viewer on logout", () => {
    const { rerender } = render(view());
    viewerDID = "did:plc:bob";
    rerender(view());
    expect(queryClient.getQueryData(aliceKey)).toBeUndefined();
    expect(queryClient.getQueryData(bobKey)).toBeDefined();
    viewerDID = undefined;
    rerender(view());
    expect(queryClient.getQueryData(bobKey)).toBeUndefined();
    expect(queryClient.getQueryData(["wireEdition"])).toBeDefined();
  });

  it("keeps an incoming viewer's cache when signing in from an anonymous state", () => {
    viewerDID = undefined;
    const { rerender } = render(view());
    viewerDID = "did:plc:alice";
    rerender(view());
    expect(queryClient.getQueryData(aliceKey)).toBeDefined();
  });
});
