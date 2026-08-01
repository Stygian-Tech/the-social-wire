import { describe, expect, it } from "bun:test";

import { articleSocialMenuActions } from "@/components/EntryDetail/articleSocialMenuActions";

describe("articleSocialMenuActions", () => {
  it("omits linked-post actions when the article has no linked post", () => {
    expect(
      articleSocialMenuActions({
        hasLinkedPost: false,
        hasCanonicalUrl: true,
        showReadLaterSave: true,
        alreadyLatrSaved: false,
      })
    ).toEqual({
      showLinkedPostActions: false,
      showPost: true,
      showSaveToReadLater: true,
      showOpenOriginal: true,
    });
  });

  it("omits the completed Read Later action", () => {
    expect(
      articleSocialMenuActions({
        hasLinkedPost: true,
        hasCanonicalUrl: true,
        showReadLaterSave: true,
        alreadyLatrSaved: true,
      }).showSaveToReadLater
    ).toBe(false);
  });
});
