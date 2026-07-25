import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import React from "react";

import { ReadRouteProvider, useReadRoute } from "@/contexts/ReadRouteContext";
import { READ_STATE_STORAGE_KEY } from "@/lib/entryReadStateStorage";
import * as AuthHook from "@/hooks/useAuth";

let restoreAuthSpy: (() => void) | undefined;

beforeEach(() => {
  window.localStorage.clear();
  const authSpy = spyOn(AuthHook, "useAuth").mockReturnValue({
    session: { did: "did:plc:viewer" },
    getOAuthSession: () => null,
  } as ReturnType<typeof AuthHook.useAuth>);
  restoreAuthSpy = () => authSpy.mockRestore();
});

afterEach(() => {
  cleanup();
  window.localStorage.clear();
  restoreAuthSpy?.();
  restoreAuthSpy = undefined;
});

function makeWrapper() {
  const queryClient = new QueryClient();
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>
        <ReadRouteProvider>{children}</ReadRouteProvider>
      </QueryClientProvider>
    );
  };
}

describe("ReadRouteProvider", () => {
  it("marks entries read and unread in local state", async () => {
    const entryId = "at://did:plc:author/site.standard.document/one";
    const { result } = renderHook(() => useReadRoute(), {
      wrapper: makeWrapper(),
    });
    await act(async () => {});

    expect(result.current.isEntryRead(entryId)).toBe(false);

    act(() => {
      result.current.markEntryRead(entryId, {
        publicationId: "at://did:plc:author/site.standard.publication/main",
      });
    });

    expect(result.current.isEntryRead(entryId)).toBe(true);
    expect(window.localStorage.getItem(READ_STATE_STORAGE_KEY) ?? "").toContain(entryId);

    act(() => {
      result.current.markEntryUnread(entryId, {
        publicationId: "at://did:plc:author/site.standard.publication/main",
      });
    });

    expect(result.current.isEntryRead(entryId)).toBe(false);
    expect(window.localStorage.getItem(READ_STATE_STORAGE_KEY)).not.toContain(entryId);
  });

  it("persists publication tab selection", async () => {
    const { result } = renderHook(() => useReadRoute(), {
      wrapper: makeWrapper(),
    });
    await act(async () => {});

    expect(result.current.publicationTab).toBe("subscribed");

    act(() => {
      result.current.setPublicationTab("following");
    });

    expect(result.current.publicationTab).toBe("following");
    expect(window.localStorage.getItem("the-social-wire.sidebar-publication-tab.v1")).toBe(
      "following"
    );
  });
});
