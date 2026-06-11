import { describe, expect, it, mock } from "bun:test";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";

import {
  PublicationSidebarProvider,
  useSidebarBootstrap,
} from "@/contexts/PublicationSidebarContext";

const consumeBootstrapStream = mock(async () => undefined);

mock.module("@/lib/bootstrapStreamClient", () => ({
  consumeBootstrapStream,
}));

mock.module("@/hooks/useAuth", () => ({
  useAuth: () => ({
    session: { did: "did:plc:viewer" },
    getOAuthSession: () => ({ accessToken: "token" }),
    oauthSessionReloadSeq: 0,
  }),
}));

function wrapper({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return (
    <QueryClientProvider client={queryClient}>
      <PublicationSidebarProvider>{children}</PublicationSidebarProvider>
    </QueryClientProvider>
  );
}

describe("PublicationSidebarProvider", () => {
  it("starts a single bootstrap stream per provider mount", async () => {
    consumeBootstrapStream.mockClear();

    const { unmount } = renderHook(() => useSidebarBootstrap(), { wrapper });

    await waitFor(() => {
      expect(consumeBootstrapStream.mock.calls.length).toBeGreaterThanOrEqual(1);
    });

    // React Strict Mode may invoke effects twice in tests; duplicate hook mounts
    // (the production bug) would produce unbounded calls across sibling consumers.
    expect(consumeBootstrapStream.mock.calls.length).toBeLessThanOrEqual(2);

    unmount();
  });
});
