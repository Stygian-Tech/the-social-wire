import type { RssArticleOpenMode } from "@/lib/feedPreferences";
import type { MergedLatrSave } from "@/lib/pdsClient";
import type { SidebarPublicationRow } from "@/lib/publicationProjectionClient";
import { recordKindFromPublication } from "@/lib/recordKindDebug";
import {
  isRssEntryId,
  normalizedFeedUrlFromRssPublicationId,
  rssEntryIdFromParts,
  stableItemKeyFromRssItem,
} from "@/lib/rssFeedCore";
import { resolveSavedLinkEmbedUrl } from "@/lib/savedLinkEmbedUrl";
import { matchSavedLinkPublicationFromSidebar } from "@/lib/savedLinkPublication";

export type SavedLinkOpenTarget =
  | { kind: "external"; url: string }
  | { kind: "rssReader"; url: string; entryId: string };

function savedRssEntryId(
  row: MergedLatrSave,
  url: string,
  sidebarRows: SidebarPublicationRow[],
): string | null {
  if (row.kind === "native" && isRssEntryId(row.subjectUri)) {
    return row.subjectUri;
  }

  const publication = matchSavedLinkPublicationFromSidebar(row, sidebarRows);
  if (
    !publication ||
    recordKindFromPublication(publication).source !== "skyreader.app"
  ) {
    return null;
  }

  const feedUrl =
    normalizedFeedUrlFromRssPublicationId(publication.publicationId) ??
    (publication.subscriptionPublicationId
      ? normalizedFeedUrlFromRssPublicationId(
          publication.subscriptionPublicationId,
        )
      : null);
  if (!feedUrl) return null;

  return rssEntryIdFromParts(
    feedUrl,
    stableItemKeyFromRssItem({ link: url }),
  );
}

export function savedLinkOpenTarget(
  row: MergedLatrSave,
  sidebarRows: SidebarPublicationRow[],
  rssArticleOpenMode: RssArticleOpenMode,
): SavedLinkOpenTarget | null {
  const url = resolveSavedLinkEmbedUrl(row);
  if (!url) return null;

  if (rssArticleOpenMode === "reader") {
    const entryId = savedRssEntryId(row, url, sidebarRows);
    if (entryId) return { kind: "rssReader", url, entryId };
  }

  return { kind: "external", url };
}
