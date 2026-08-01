"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { LogOut, Bookmark, Archive } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarResizeHandle,
} from "@/components/ui/sidebar";
import { Avatar } from "@/components/shared/Avatar";
import { SidebarFoldersSection } from "./SidebarFoldersSection";
import { SidebarPublicationsSection } from "./SidebarPublicationsSection";
import { useAuth } from "@/hooks/useAuth";
import {
  useSidebarBootstrap,
  useSidebarProjection,
} from "@/contexts/PublicationSidebarContext";
import { usePrefetchSidebarPublicationEntries } from "@/hooks/usePrefetchSidebarPublicationEntries";
import { useCrossClientReadSync } from "@/hooks/useCrossClientReadSync";
import { useSidebarUnreadController } from "@/hooks/useSidebarUnreadController";
import { useReadState } from "@/contexts/ReadStateContext";
import { useSidebarChrome } from "@/contexts/SidebarChromeContext";
import { useReadSidebarScopeOptional } from "@/contexts/ReadSidebarScopeContext";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import { useLatrMergedHttpsSaves } from "@/hooks/useLatrSaved";
import { rkeyFromURI } from "@/lib/pdsClient";
import { type DiscoveredPublication } from "@/lib/atprotoClient";
import { sumUnreadForPublications } from "@/lib/unreadCounts";
import { PublicationTabs } from "./PublicationTabs";
import { ReadLaterSidebarBadge } from "./ReadLaterSidebarBadge";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import { defaultSidebarExpandedKeys } from "@/lib/sidebarExpandedKeysStorage";
import {
  DEFAULT_FEED_DISPLAY_PREFERENCES,
  feedDisplaysUnreadCount,
  nextVisibleFeed,
  type TopLevelFeed,
} from "@/lib/feedPreferences";
import { sidebarPublicationRows } from "@/lib/publicationProjectionClient";
import { savedFeedSources } from "@/lib/savedFeedSources";
import { SavedFeedSourcesSection } from "./SavedFeedSourcesSection";
import { activeReadFeedScope } from "@/lib/activeReadFeedScope";
import { useClientHydrated } from "@/hooks/useClientHydrated";
import { AllFeedSidebarButton } from "./AllFeedSidebarButton";
import {
  currentAppSidebarFeed,
  isAllFeedRouteSelected,
} from "./appSidebarFeedSelection";
import { MobileFeedNavigation } from "./MobileFeedNavigation";
import { FeedbackDialog } from "./FeedbackDialog";
import { AppSidebarBrandHeader } from "./AppSidebarBrandHeader";

interface AppSidebarProps {
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
  showPublicationsRail?: boolean;
}

const SERVER_SIDEBAR_EXPANDED_KEYS = defaultSidebarExpandedKeys();
const SERVER_PUBLICATION_UNREAD_COUNTS = new Map<string, number>();

export function AppSidebar({
  selectedPubId,
  onSelectPub,
  showPublicationsRail = true,
}: AppSidebarProps) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const { session, signOut } = useAuth();
  const clientHydrated = useClientHydrated();
  const [loggingOut, setLoggingOut] = useState(false);
  const {
    selectedFolderUri,
    setSelectedFolderUri,
    publicationTab,
    setPublicationTab,
    sidebarExpandedKeys,
    toggleSidebarExpandedKey,
    syncSidebarFolderExpandKeys,
  } = useSidebarChrome();
  const { isEntryRead, readEpoch } = useReadState();

  async function handleLogout() {
    setLoggingOut(true);
    try {
      await signOut();
    } catch (err) {
      console.warn("Sign-out failed; redirecting to login", err);
    } finally {
      router.replace("/login");
      setLoggingOut(false);
    }
  }

  const {
    folders,
    prefsMap,
    allPublicationRows,
    folderMap,
    unfolderedPubs,
    followingTabPublications,
    unreadCountsByPublicationId,
    publicationSidebarProjection,
  } = useSidebarProjection();
  const {
    folderPublicationsLoading: folderPublicationsListLoading,
    foldersListLoading,
    subscribedPublicationsLoading,
    followingPublicationsLoading,
    streamSelectedPublicationId,
    hasSidebarSnapshot,
    bootstrapStreamComplete,
  } = useSidebarBootstrap();
  const folderPublicationsLoading = folderPublicationsListLoading;
  const sidebarDependentDataEnabled = hasSidebarSnapshot && !!session;
  const secondaryReaderSyncEnabled =
    sidebarDependentDataEnabled && bootstrapStreamComplete;
  const { data: savedLinks = [] } = useLatrMergedHttpsSaves("active", {
    enabled: sidebarDependentDataEnabled,
  });
  const { data: archivedLinks = [] } = useLatrMergedHttpsSaves("archived", {
    enabled: sidebarDependentDataEnabled,
  });
  const { preferences: feedPreferences } = useFeedDisplayPreferences();
  const savedSidebarRows = useMemo(
    () =>
      publicationSidebarProjection
        ? sidebarPublicationRows(publicationSidebarProjection)
        : [],
    [publicationSidebarProjection],
  );
  const activeSavedRows = pathname.startsWith("/archive")
    ? archivedLinks
    : savedLinks;
  const savedSources = useMemo(
    () => savedFeedSources(activeSavedRows, savedSidebarRows),
    [activeSavedRows, savedSidebarRows],
  );
  const selectedSavedSource = searchParams.get("source");
  const selectedFolderRkey = searchParams.get("folder");
  const currentFeed = currentAppSidebarFeed({
    pathname,
    feedParam: searchParams.get("feed"),
    folderParam: selectedFolderRkey,
    publicationTab,
  });
  const allFeedSelected = isAllFeedRouteSelected({
    pathname,
    sourceParam: selectedSavedSource,
    folderParam: selectedFolderRkey,
  });

  useCrossClientReadSync(secondaryReaderSyncEnabled);

  usePrefetchSidebarPublicationEntries(
    allPublicationRows,
    hasSidebarSnapshot && !!session && bootstrapStreamComplete,
    selectedPubId ?? streamSelectedPublicationId,
    unreadCountsByPublicationId
  );

  const { data: profile, isLoading: profileLoading } = useViewerProfile();

  const subscribedPublications = useMemo(() => {
    const seen = new Set<string>();
    const list: DiscoveredPublication[] = [];
    for (const f of folders) {
      const rkey = rkeyFromURI(f.uri);
      for (const p of folderMap.get(rkey) ?? []) {
        if (!seen.has(p.publicationId)) {
          seen.add(p.publicationId);
          list.push(p);
        }
      }
    }
    for (const p of unfolderedPubs) {
      if (!seen.has(p.publicationId)) {
        seen.add(p.publicationId);
        list.push(p);
      }
    }
    return list;
  }, [folders, folderMap, unfolderedPubs]);

  const publicationsForUnread = useMemo(() => {
    const seen = new Set<string>();
    return [...subscribedPublications, ...followingTabPublications].filter(
      (publication) => seen.add(publication.publicationId),
    );
  }, [followingTabPublications, subscribedPublications]);

  const publicationUnreadCounts = useSidebarUnreadController({
    publications: publicationsForUnread,
    unreadCountsByPublicationId: clientHydrated
      ? unreadCountsByPublicationId
      : SERVER_PUBLICATION_UNREAD_COUNTS,
    isEntryRead: clientHydrated ? isEntryRead : undefined,
    readEpoch,
  });

  const setActiveReadFeedScope =
    useReadSidebarScopeOptional()?.setActiveFeedScope;

  useEffect(() => {
    if (!setActiveReadFeedScope) return;

    const folderRkey = selectedFolderRkey;
    const folderName = folderRkey
      ? folders.find((folder) => rkeyFromURI(folder.uri) === folderRkey)?.value
          .name
      : undefined;
    const selectedPublication = selectedPubId
      ? allPublicationRows.find(
          (publication) => publication.publicationId === selectedPubId,
        )
      : undefined;
    const next = activeReadFeedScope({
      folderRkey,
      folderName,
      folderPublications: folderRkey ? (folderMap.get(folderRkey) ?? []) : [],
      selectedPublication,
      selectedTopLevelFeed:
        currentFeed === "following" ? "following" : "subscribed",
      subscribedPublications,
      followingPublications: followingTabPublications,
    });

    setActiveReadFeedScope((prev) => {
      if (
        prev.gatewayScope?.kind === next.gatewayScope.kind &&
        prev.displayName === next.displayName &&
        (prev.gatewayScope?.kind !== "publication" ||
          next.gatewayScope.kind !== "publication" ||
          prev.gatewayScope.publicationId === next.gatewayScope.publicationId) &&
        (prev.gatewayScope?.kind !== "folder" ||
          next.gatewayScope.kind !== "folder" ||
          prev.gatewayScope.folderRkey === next.gatewayScope.folderRkey) &&
        prev.publications.length === next.publications.length &&
        prev.publications.every(
          (publication, index) =>
            publication.publicationId ===
            next.publications[index]?.publicationId,
        )
      ) {
        return prev;
      }
      return next;
    });
  }, [
    allPublicationRows,
    folders,
    folderMap,
    followingTabPublications,
    selectedPubId,
    selectedFolderRkey,
    currentFeed,
    setActiveReadFeedScope,
    subscribedPublications,
  ]);

  const allFolderedPublicationsForBulk = useMemo(() => {
    const seen = new Set<string>();
    const list: DiscoveredPublication[] = [];
    for (const f of folders) {
      const rkey = rkeyFromURI(f.uri);
      for (const p of folderMap.get(rkey) ?? []) {
        if (!seen.has(p.publicationId)) {
          seen.add(p.publicationId);
          list.push(p);
        }
      }
    }
    return list;
  }, [folders, folderMap]);

  const effectiveExpandedKeys = clientHydrated
    ? sidebarExpandedKeys
    : SERVER_SIDEBAR_EXPANDED_KEYS;

  useEffect(() => {
    syncSidebarFolderExpandKeys(folders.map((f) => f.uri));
  }, [folders, syncSidebarFolderExpandKeys]);

  useEffect(() => {
    if (!selectedPubId) return;
    setSelectedFolderUri(null);
  }, [selectedPubId, setSelectedFolderUri]);

  useEffect(() => {
    if (!currentFeed) return;
    if (feedPreferences.visibleFeeds.includes(currentFeed)) return;
    const replacement = nextVisibleFeed(
      currentFeed,
      feedPreferences.visibleFeeds,
    );
    if (replacement === "readLater") router.replace("/saved");
    else if (replacement === "archive") router.replace("/archive");
    else router.replace(`/read?feed=${replacement}`);
  }, [currentFeed, feedPreferences.visibleFeeds, router]);

  const showFeedCount = (feed: TopLevelFeed) =>
    clientHydrated && feedDisplaysUnreadCount(feedPreferences, feed);
  const subscribedUnread = sumUnreadForPublications(
    subscribedPublications,
    publicationUnreadCounts,
  );
  const followingUnread = sumUnreadForPublications(
    followingTabPublications,
    publicationUnreadCounts,
  );
  const readLaterUnread = savedLinks.filter(
    (row) => !isEntryRead(row.subjectUri) && !row.lastOpenedAt,
  ).length;
  const archiveUnread = archivedLinks.filter(
    (row) => !isEntryRead(row.subjectUri) && !row.lastOpenedAt,
  ).length;
  const displayedReadLaterUnread = showFeedCount("readLater")
    ? readLaterUnread
    : 0;
  const displayedArchiveUnread = showFeedCount("archive") ? archiveUnread : 0;
  const visible = new Set<TopLevelFeed>(
    clientHydrated
      ? feedPreferences.visibleFeeds
      : DEFAULT_FEED_DISPLAY_PREFERENCES.visibleFeeds,
  );

  const selectTopLevelFeed = (feed: TopLevelFeed) => {
    setSelectedFolderUri(null);
    if (feed === "readLater") {
      router.push("/saved");
      return;
    }
    if (feed === "archive") {
      router.push("/archive");
      return;
    }
    setPublicationTab(feed);
    router.push(`/read?feed=${feed}`);
  };

  useEffect(() => {
    if (currentFeed === "subscribed" || currentFeed === "following") {
      setPublicationTab(currentFeed);
    }
  }, [currentFeed, setPublicationTab]);

  return (
    <>
    <Sidebar
      className="transition-[width] [&_[data-slot=sidebar-inner]]:bg-background"
      style={{ left: "max(0px, calc((100vw - 70rem) / 2))" }}
    >
      <AppSidebarBrandHeader />

      <SidebarContent className="overflow-y-auto overflow-x-hidden">
        <div className="shrink-0">
          {visible.has("readLater") || visible.has("archive") ? (
          <SidebarGroup className="pb-1">
            <SidebarGroupLabel>Read Later</SidebarGroupLabel>
            <SidebarMenu className="gap-0.5">
              {visible.has("readLater") ? <SidebarMenuItem>
                <SidebarMenuButton
                  type="button"
                  tooltip="Read Later Links"
                  isActive={currentFeed === "readLater"}
                  onClick={() => selectTopLevelFeed("readLater")}
                  className={displayedReadLaterUnread > 0 ? "relative pr-8" : undefined}
                >
                  <Bookmark />
                  <span>Saved</span>
                  <ReadLaterSidebarBadge
                    count={displayedReadLaterUnread}
                  />
                </SidebarMenuButton>
              </SidebarMenuItem> : null}
              {visible.has("archive") ? <SidebarMenuItem>
                <SidebarMenuButton
                  type="button"
                  tooltip="Archived Read Later Links"
                  isActive={currentFeed === "archive"}
                  onClick={() => selectTopLevelFeed("archive")}
                  className={displayedArchiveUnread > 0 ? "relative pr-8" : undefined}
                >
                  <Archive />
                  <span>Archive</span>
                  <ReadLaterSidebarBadge
                    count={displayedArchiveUnread}
                  />
                </SidebarMenuButton>
              </SidebarMenuItem> : null}
            </SidebarMenu>
          </SidebarGroup>
          ) : null}
          <PublicationTabs
            activeTab={
              currentFeed === "subscribed" || currentFeed === "following"
                ? currentFeed
                : null
            }
            onTabChange={selectTopLevelFeed}
            subscribedUnread={subscribedUnread}
            followingUnread={followingUnread}
            showSubscribedUnreadCount={showFeedCount("subscribed")}
            showFollowingUnreadCount={showFeedCount("following")}
            subscribedPublications={subscribedPublications}
            followingPublications={followingTabPublications}
            visibleTabs={[
              ...(visible.has("subscribed") ? ["subscribed" as const] : []),
              ...(visible.has("following") ? ["following" as const] : []),
            ]}
          />
        </div>
        {showPublicationsRail ? (
        <div className="flex min-w-0 flex-col gap-0 group-data-[collapsible=icon]:overflow-hidden lg:fixed lg:bottom-0 lg:right-[max(0px,calc((100vw-70rem)/2))] lg:top-[var(--environment-banner-height,0px)] lg:z-30 lg:w-64 lg:overflow-y-auto lg:border-l lg:border-sidebar-border/70 lg:bg-background">
          <div className="hidden min-h-12 shrink-0 items-end px-4 pb-1 lg:flex">
            <p className="text-base font-bold text-sidebar-foreground">
              Publications
            </p>
          </div>
          <SidebarGroup className="px-3 pb-4 pt-1">
            {currentFeed ? (
              <AllFeedSidebarButton
                feed={currentFeed}
                isActive={allFeedSelected}
                onSelect={selectTopLevelFeed}
              />
            ) : null}
            <SidebarMenu className="gap-2">
              {pathname.startsWith("/saved") ||
              pathname.startsWith("/archive") ? (
                <SavedFeedSourcesSection
                  sources={savedSources}
                  selectedSource={selectedSavedSource}
                  onSelectSource={(sourceKey) =>
                    router.push(
                      `${pathname.startsWith("/archive") ? "/archive" : "/saved"}?source=${encodeURIComponent(sourceKey)}`,
                    )
                  }
                />
              ) : currentFeed === "subscribed" ? (
                <>
                  <SidebarFoldersSection
                    folders={folders}
                    folderMap={folderMap}
                    foldersListLoading={foldersListLoading}
                    folderPublicationsLoading={folderPublicationsLoading}
                    effectiveExpandedKeys={effectiveExpandedKeys}
                    selectedFolderUri={
                      searchParams.get("folder") ?? selectedFolderUri
                    }
                    selectedPubId={selectedPubId}
                    onSelectPub={onSelectPub}
                    onToggleFolder={toggleSidebarExpandedKey}
                    onSelectFolder={(folderUri, folderRkey) => {
                      setSelectedFolderUri(folderUri);
                      router.push(
                        `/read?folder=${encodeURIComponent(folderRkey)}`,
                      );
                    }}
                    prefsMap={prefsMap}
                    publicationUnreadCounts={publicationUnreadCounts}
                    allFolderedPublicationsForBulk={allFolderedPublicationsForBulk}
                  />
                  <SidebarPublicationsSection
                    publications={unfolderedPubs}
                    publicationUnreadCounts={publicationUnreadCounts}
                    selectedPubId={selectedPubId}
                    onSelectPub={onSelectPub}
                    folders={folders}
                    prefsMap={prefsMap}
                    sidebarTab="subscribed"
                    listLoading={subscribedPublicationsLoading}
                    readBulkMarkAllReadConfirmation={
                      <>
                        This marks every cached article in Publications (sources not in a
                        folder) as read. Entries that have not been loaded yet stay unchanged
                        until you open them.
                      </>
                    }
                  />
                </>
              ) : (
                <SidebarPublicationsSection
                  publications={followingTabPublications}
                  publicationUnreadCounts={publicationUnreadCounts}
                  selectedPubId={selectedPubId}
                  onSelectPub={onSelectPub}
                  folders={folders}
                  prefsMap={prefsMap}
                  sidebarTab="following"
                  listLoading={followingPublicationsLoading}
                  readBulkMarkAllReadConfirmation={
                    <>
                      This marks every cached article from publications you follow as read.
                      Entries that have not been loaded yet stay unchanged until you open
                      them.
                    </>
                  }
                  gatewayMarkAllReadScopes={[{ kind: "following" }]}
                />
              )}
            </SidebarMenu>
          </SidebarGroup>
        </div>
        ) : null}
      </SidebarContent>

      <div className="px-3 pb-2">
        <SidebarMenu>
          <SidebarMenuItem>
            <FeedbackDialog />
          </SidebarMenuItem>
        </SidebarMenu>
      </div>
      <SidebarFooter className="border-t border-sidebar-border/70 px-2 py-3">
        <SidebarMenu className="gap-0.5 px-1">
          {profileLoading ? (
            <SidebarMenuItem>
              <div className="flex min-w-0 flex-1 items-start gap-2 px-1 py-1">
                <Skeleton className="size-6 shrink-0 rounded-full" />
                <div className="flex min-w-0 flex-1 flex-col gap-1.5 pt-0.5">
                  <Skeleton className="h-4 w-28" />
                  <Skeleton className="h-3 w-full max-w-[12rem]" />
                </div>
              </div>
            </SidebarMenuItem>
          ) : (
            <SidebarMenuItem>
              <SidebarMenuButton
                tooltip="Your Profile & Publications"
                isActive={pathname.startsWith("/me")}
                render={<Link href="/me#publications" prefetch />}
                className="h-auto min-h-0 items-start gap-2 overflow-visible py-1.5 pl-1 whitespace-normal"
              >
                <Avatar
                  src={profile?.avatar}
                  alt={profile?.displayName || profile?.handle || session?.did || "Account"}
                  size={24}
                  className="shrink-0"
                />
                <div className="min-w-0 flex-1 py-px text-left">
                  <p className="truncate text-sm font-medium leading-tight">
                    {profile?.displayName?.trim() ||
                      profile?.handle ||
                      session?.did ||
                      "—"}
                  </p>
                  <p className="truncate text-[11px] leading-snug text-muted-foreground">
                    {profile?.handle ?? session?.did ?? ""}
                  </p>
                </div>
              </SidebarMenuButton>
            </SidebarMenuItem>
          )}
          <SidebarMenuItem>
            <SidebarMenuButton
              type="button"
              tooltip="Log Out"
              disabled={loggingOut}
              onClick={() => void handleLogout()}
            >
              <LogOut />
              <span>{loggingOut ? "Signing Out…" : "Log Out"}</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
      <SidebarResizeHandle />
    </Sidebar>
    <MobileFeedNavigation
      currentFeed={currentFeed}
      visibleFeeds={visible}
      onSelect={selectTopLevelFeed}
    />
    </>
  );
}
