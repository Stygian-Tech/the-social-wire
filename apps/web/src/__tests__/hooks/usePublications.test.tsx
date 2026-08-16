import { describe, expect, it } from "bun:test";
import {
  PUBLICATION_SUBSCRIPTIONS_QUERY_KEY,
} from "@/hooks/usePublications";

describe("usePublications query keys", () => {
  it("PUBLICATION_SUBSCRIPTIONS_QUERY_KEY is stable", () => {
    expect(PUBLICATION_SUBSCRIPTIONS_QUERY_KEY).toEqual([
      "publicationSubscriptions",
    ]);
  });
});
