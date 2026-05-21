import { describe, expect, it } from "bun:test";
import { renderHook } from "@testing-library/react";
import { useSidebarUnreadCounts } from "@/hooks/useSidebarUnreadCounts";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

const pub: DiscoveredPublication = {
  publicationId: "did:plc:alice",
  subscriptionPublicationId: "did:plc:alice",
  authorDid: "did:plc:alice",
  authorHandle: "alice.test",
  title: "Alice",
  discoveredAt: "2026-01-01T00:00:00.000Z",
};

describe("useSidebarUnreadCounts", () => {
  it("maps API unread counts by publication id", () => {
    const unreadCountsByPublicationId = new Map([
      ["did:plc:alice", 3],
    ]);

    const { result } = renderHook(() =>
      useSidebarUnreadCounts([pub], unreadCountsByPublicationId)
    );

    expect(result.current.get("did:plc:alice")).toBe(3);
  });

  it("returns zero when no API counts are present", () => {
    const { result } = renderHook(() =>
      useSidebarUnreadCounts([pub], undefined)
    );

    expect(result.current.get("did:plc:alice")).toBe(0);
  });
});
