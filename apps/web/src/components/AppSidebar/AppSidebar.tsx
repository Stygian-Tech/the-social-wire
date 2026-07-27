"use client";

import Image from "next/image";
import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { LogOut, RefreshCw, Bookmark, Archive } from "lucide-react";
import iconSrc from "@/app/icon.png";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupLabel,
  SidebarHeader,
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
import {
  nextVisibleFeed,
  type TopLevelFeed,
} from "@/lib/feedPreferences";
import { sidebarPublicationRows } from "@/lib/publicationProjectionClient";
import { savedFeedSources } from "@/lib/savedFeedSources";
import { SavedFeedSourcesSection } from "./SavedFeedSourcesSection";
import { activeReadFeedScope } from "@/lib/activeReadFeedScope";

interface AppSidebarProps {
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
}

export function AppSidebar({ selectedPubId, onSelectPub }: AppSidebarProps) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const { session, signOut } = useAuth();
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
    refresh,
    folderPublicationsLoading: folderPublicationsListLoading,
    foldersListLoading,
    subscribedPublicationsLoading,
    followingPublicationsLoading,
    streamSelectedPublicationId,
    hasSidebarSnapshot,
    bootstrapStreamComplete,
  } = useSidebarBootstrap();
  const folderPublicationsLoading = folderPublicationsListLoading;
  const secondaryReaderSyncEnabled = hasSidebarSnapshot && bootstrapStreamComplete;
  const { data: savedLinks = [] } = useLatrMergedHttpsSaves("active", {
    enabled: secondaryReaderSyncEnabled,
  });
  const { data: archivedLinks = [] } = useLatrMergedHttpsSaves("archived", {
    enabled: secondaryReaderSyncEnabled,
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
    unreadCountsByPublicationId,
    isEntryRead,
    readEpoch,
  });

  const setActiveReadFeedScope =
    useReadSidebarScopeOptional()?.setActiveFeedScope;

  useEffect(() => {
    if (!setActiveReadFeedScope) return;

    const folderRkey = searchParams.get("folder");
    const selectedPublication = selectedPubId
      ? allPublicationRows.find(
          (publication) => publication.publicationId === selectedPubId,
        )
      : undefined;
    const next = activeReadFeedScope({
      folderRkey,
      folderPublications: folderRkey ? (folderMap.get(folderRkey) ?? []) : [],
      selectedPublication,
      selectedTopLevelFeed:
        searchParams.get("feed") === "following" ? "following" : "subscribed",
      subscribedPublications,
      followingPublications: followingTabPublications,
    });

    setActiveReadFeedScope((prev) => {
      if (
        prev.gatewayScope?.kind === next.gatewayScope.kind &&
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
    folderMap,
    followingTabPublications,
    searchParams,
    selectedPubId,
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

  const effectiveExpandedKeys = sidebarExpandedKeys;

  useEffect(() => {
    syncSidebarFolderExpandKeys(folders.map((f) => f.uri));
  }, [folders, syncSidebarFolderExpandKeys]);

  useEffect(() => {
    if (!selectedPubId) return;
    setSelectedFolderUri(null);
  }, [selectedPubId, setSelectedFolderUri]);

  const selectedFeed =
    pathname.startsWith("/saved") && !selectedSavedSource
      ? "readLater"
      : pathname.startsWith("/archive") && !selectedSavedSource
        ? "archive"
        : pathname === "/read" && !searchParams.get("folder")
          ? searchParams.get("feed") === "following"
            ? "following"
            : "subscribed"
          : null;

  useEffect(() => {
    if (!selectedFeed) return;
    if (feedPreferences.visibleFeeds.includes(selectedFeed)) return;
    const replacement = nextVisibleFeed(
      selectedFeed,
      feedPreferences.visibleFeeds,
    );
    if (replacement === "readLater") router.replace("/saved");
    else if (replacement === "archive") router.replace("/archive");
    else router.replace(`/read?feed=${replacement}`);
  }, [feedPreferences.visibleFeeds, router, selectedFeed]);

  const showTopLevelCounts =
    feedPreferences.showTopLevelFeedUnreadCounts;
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
  const visible = new Set<TopLevelFeed>(feedPreferences.visibleFeeds);

  const selectPublicationTab = (tab: "subscribed" | "following") => {
    setPublicationTab(tab);
    setSelectedFolderUri(null);
    router.push(`/read?feed=${tab}`);
  };

  useEffect(() => {
    if (selectedFeed === "subscribed" || selectedFeed === "following") {
      setPublicationTab(selectedFeed);
    }
  }, [selectedFeed, setPublicationTab]);

  return (
    <Sidebar>
      <SidebarHeader className="border-b bg-sidebar/85 px-4 py-3 backdrop-blur-md">
        <div className="flex min-w-0 items-center justify-between gap-2">
          <div className="flex min-w-0 items-center gap-2">
            <Image
              src={iconSrc}
              alt=""
              width={24}
              height={24}
              className="shrink-0 rounded"
            />
            <div className="flex min-w-0 flex-col items-start gap-0.5">
              <span className="truncate text-sm font-bold leading-tight text-sidebar-foreground">
                The Social Wire
              </span>
              <span className="inline-flex shrink-0 items-center rounded-full border border-[var(--purple-border)] bg-primary/10 px-1.5 py-0.5 text-[10px] font-bold leading-none text-[var(--purple-foreground)]">
                Beta
              </span>
            </div>
          </div>
          <Button
            variant="ghost"
            size="icon-sm"
            className="size-8 shrink-0 rounded-md border-0 bg-transparent shadow-none hover:bg-sidebar-accent/50 hover:text-sidebar-accent-foreground"
            onClick={() => refresh.mutate()}
            disabled={refresh.isPending}
            title="Refresh Publications"
          >
            <RefreshCw
              className={`h-3.5 w-3.5 ${refresh.isPending ? "animate-spin" : ""}`}
            />
          </Button>
        </div>
      </SidebarHeader>

      <SidebarContent className="overflow-y-auto overflow-x-hidden">
        <div className="shrink-0 bg-sidebar/85 backdrop-blur-md">
          {visible.has("readLater") || visible.has("archive") ? (
          <SidebarGroup className="pb-1">
            <SidebarGroupLabel>Read Later</SidebarGroupLabel>
            <SidebarMenu className="gap-0.5">
              {visible.has("readLater") ? <SidebarMenuItem>
                <SidebarMenuButton
                  type="button"
                  tooltip="Read Later Links"
                  isActive={
                    pathname.startsWith("/saved") && !selectedSavedSource
                  }
                  onClick={() => router.push("/saved")}
                  className={readLaterUnread > 0 ? "relative pr-8" : undefined}
                >
                  <Bookmark />
                  <span>Saved</span>
                  <ReadLaterSidebarBadge
                    count={showTopLevelCounts ? readLaterUnread : 0}
                  />
                </SidebarMenuButton>
              </SidebarMenuItem> : null}
              {visible.has("archive") ? <SidebarMenuItem>
                <SidebarMenuButton
                  type="button"
                  tooltip="Archived Read Later Links"
                  isActive={
                    pathname.startsWith("/archive") && !selectedSavedSource
                  }
                  onClick={() => router.push("/archive")}
                  className={archiveUnread > 0 ? "relative pr-8" : undefined}
                >
                  <Archive />
                  <span>Archive</span>
                  <ReadLaterSidebarBadge
                    count={showTopLevelCounts ? archiveUnread : 0}
                  />
                </SidebarMenuButton>
              </SidebarMenuItem> : null}
            </SidebarMenu>
          </SidebarGroup>
          ) : null}
          <PublicationTabs
            activeTab={
              selectedFeed === "subscribed" || selectedFeed === "following"
                ? selectedFeed
                : null
            }
            onTabChange={selectPublicationTab}
            subscribedUnread={subscribedUnread}
            followingUnread={followingUnread}
            showUnreadCounts={showTopLevelCounts}
            visibleTabs={[
              ...(visible.has("subscribed") ? ["subscribed" as const] : []),
              ...(visible.has("following") ? ["following" as const] : []),
            ]}
          />
        </div>
        <div className="flex min-w-0 flex-col gap-0 group-data-[collapsible=icon]:overflow-hidden">
          <SidebarGroup className="px-2 pb-2 pt-2">
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
              ) : publicationTab === "subscribed" ? (
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
      </SidebarContent>

      <SidebarFooter className="border-t bg-sidebar/85 px-2 py-2 backdrop-blur-md">
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
  );
}
