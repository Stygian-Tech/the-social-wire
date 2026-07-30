import { describe, expect, it } from "bun:test";
import {
  STANDARD_SITE_RECOMMEND_COLLECTION,
  standardSiteRecommendDocumentUri,
} from "@/lib/standardSiteRecommendation";

describe("standard.site recommendations", () => {
  it("accepts only canonical site.standard.document records", () => {
    expect(
      standardSiteRecommendDocumentUri(
        "at://did:plc:author/site.standard.document/article"
      )
    ).toBe("at://did:plc:author/site.standard.document/article");
    expect(
      standardSiteRecommendDocumentUri(
        "at%3A%2F%2Fdid%3Aplc%3Aauthor%2Fsite.standard.document%2Farticle"
      )
    ).toBe("at://did:plc:author/site.standard.document/article");
    expect(
      standardSiteRecommendDocumentUri(
        "at://did:plc:author/site.standard.entry/article"
      )
    ).toBeNull();
    expect(
      standardSiteRecommendDocumentUri(
        "at://did:plc:author/app.bsky.feed.post/article"
      )
    ).toBeNull();
    expect(standardSiteRecommendDocumentUri("rss:https://example.com")).toBeNull();
  });

  it("uses the published recommend collection", () => {
    expect(STANDARD_SITE_RECOMMEND_COLLECTION).toBe(
      "site.standard.graph.recommend"
    );
  });
});
