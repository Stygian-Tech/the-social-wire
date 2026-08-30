import type { ReaderNavigationFeed } from "@/lib/feedPreferences";
import type { PublicationTab } from "./appSidebarConstants";

export function currentAppSidebarFeed({
  pathname,
  feedParam,
  folderParam,
  publicationTab,
}: {
  pathname: string;
  feedParam: string | null;
  folderParam: string | null;
  publicationTab: PublicationTab;
}): ReaderNavigationFeed | null {
  if (pathname.startsWith("/saved")) return "readLater";
  if (pathname.startsWith("/archive")) return "archive";
  if (!pathname.startsWith("/read")) return null;
  if (folderParam) return "subscribed";
  if (feedParam === "wire") return "wire";
  if (feedParam === "circle") return "circle";
  if (feedParam === "following") return "following";
  if (feedParam === "subscribed") return "subscribed";
  return publicationTab;
}

export function isAllFeedRouteSelected({
  pathname,
  sourceParam,
  folderParam,
}: {
  pathname: string;
  sourceParam: string | null;
  folderParam: string | null;
}): boolean {
  if (pathname.startsWith("/saved") || pathname.startsWith("/archive")) {
    return !sourceParam;
  }
  return pathname === "/read" && !folderParam;
}
