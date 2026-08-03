interface ArticleSocialMenuActionOptions {
  hasLinkedPost: boolean;
  hasCanonicalUrl: boolean;
  showReadLaterSave: boolean;
  alreadyLatrSaved: boolean;
}

export function articleSocialMenuActions({
  hasLinkedPost,
  hasCanonicalUrl,
  showReadLaterSave,
  alreadyLatrSaved,
}: ArticleSocialMenuActionOptions) {
  return {
    showLinkedPostActions: hasLinkedPost,
    showPost: hasCanonicalUrl,
    showSaveToReadLater:
      showReadLaterSave && hasCanonicalUrl && !alreadyLatrSaved,
    showOpenOriginal: hasCanonicalUrl,
  };
}
