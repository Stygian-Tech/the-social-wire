import { describe, expect, it } from "bun:test";
import {
  DISCOVERY_QUERY_KEY,
  PUBLICATION_SUBSCRIPTIONS_QUERY_KEY,
} from "@/hooks/usePublications";

describe("usePublications query keys", () => {
  it("DISCOVERY_QUERY_KEY includes viewer DID", () => {
    expect(DISCOVERY_QUERY_KEY("did:plc:viewer")).toEqual([
      "discovery",
      "publication-icons-v1",
      "did:plc:viewer",
    ]);
  });

  it("PUBLICATION_SUBSCRIPTIONS_QUERY_KEY is stable", () => {
    expect(PUBLICATION_SUBSCRIPTIONS_QUERY_KEY).toEqual([
      "publicationSubscriptions",
    ]);
  });
});
