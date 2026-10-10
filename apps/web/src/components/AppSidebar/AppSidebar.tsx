"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
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
  useSidebar,
} from "@/components/ui/sidebar";
import { floatingSidebarClassName } from "@/components/shared/floatingSidebarStyles";
import { Avatar } from "@/components/shared/Avatar";
import { SidebarFoldersSection } from "./SidebarFoldersSection";
import { SidebarListPublicationsSection } from "./SidebarListPublicationsSection";
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
import { useConfiguredReadLaterService } from "@/hooks/useReadLaterPreferences";
import { useSembleCollectionItems } from "@/hooks/useSembleReadLater";
import { rkeyFromURI } from "@/lib/pdsClient";
import { type DiscoveredPublication } from "@/lib/atprotoClient";
import { sumUnreadForPublications } from "@/lib/unreadCounts";
import { PublicationTabs } from "./PublicationTabs";
import { SidebarAudioSection } from "./SidebarAudioSection";
import { podcastsEnabled } from "@/lib/podcasts/playback";
import { SidebarTopicsSection } from "./SidebarTopicsSection";
import { ReadLaterSidebarBadge } from "./ReadLaterSidebarBadge";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import { defaultSidebarExpandedKeys } from "@/lib/sidebarExpandedKeysStorage";
import {
  DEFAULT_FEED_DISPLAY_PREFERENCES,
  feedDisplaysUnreadCount,
  type TopLevelFeed,
  type ReaderNavigationFeed,
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
import { SidebarListsSection } from "./SidebarListsSection";
import { useStandardReaderList, useStandardReaderLists } from "@/hooks/useStandardReaderLists";
import type { StandardReaderList } from "@/lib/standardReaderListsClient";
import { AppSidebarBrandHeader } from "./AppSidebarBrandHeader";
import { useFinanceCatalog } from "@/hooks/useFinanceCatalog";
import { financeTopicIsVisible } from "@/lib/financeFeedClient";
import { useSportsCatalog } from "@/hooks/useSportsCatalog";
import { sportsTopicIsVisible } from "@/lib/sportsFeedClient";
import { useWireFeedCatalog } from "@/hooks/useWireFeed";
import {
  loadReaderFeedSelection,
  saveReaderFeedSelection,
} from "@/lib/readerFeedSelectionStorage";
import { SIDEBAR_PUBLICATION_TAB_STORAGE_KEY } from "@/lib/sidebarPublicationTabStorage";
import { readLaterSidebarButtonClassName } from "./readLaterSidebarButtonStyles";

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
  const { setOpenMobile } = useSidebar();
  const readerLists = useStandardReaderLists();
  const viewerDidRef = useRef(session?.did);
  const creatorSearchEpoch = useRef(0);
  useEffect(() => { viewerDidRef.current = session?.did; creatorSearchEpoch.current += 1; }, [session?.did]);
  const [listsSearching, setListsSearching] = useState(false);
  const [creatorResults, setCreatorResults] = useState<StandardReaderList[]>([]);
  const selectedListUri = pathname === "/read" ? searchParams.get("list") : null;
  const selectedList = useStandardReaderList(selectedListUri);
  const selectedListUriRef = useRef(selectedListUri);
  useEffect(() => {
    selectedListUriRef.current = selectedListUri;
  }, [selectedListUri]);
  useEffect(() => { queueMicrotask(() => { setCreatorResults([]); setListsSearching(false); }); }, [session?.did]);
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
  const configuredReadLater = useConfiguredReadLaterService();
  const usingSemble = configuredReadLater.serviceId === "semble";
  const { data: savedLinks = [] } = useLatrMergedHttpsSaves("active", {
    enabled: sidebarDependentDataEnabled && !usingSemble,
  });
  const { data: archivedLinks = [] } = useLatrMergedHttpsSaves("archived", {
    enabled: sidebarDependentDataEnabled && !usingSemble,
  });
  const sembleItems = useSembleCollectionItems(
    configuredReadLater.sembleConnection?.collectionUri,
    { enabled: sidebarDependentDataEnabled && usingSemble },
  );
  const { preferences: feedPreferences } = useFeedDisplayPreferences();
  const wireCatalog = useWireFeedCatalog();
  const sportsCatalog = useSportsCatalog();
  const financeCatalog = useFinanceCatalog();
  const wireNavigationEnabled =
    feedPreferences.showWire &&
    wireCatalog.data?.enabled === true &&
    wireCatalog.data.available === true;
  const savedSidebarRows = useMemo(
    () =>
      publicationSidebarProjection
        ? sidebarPublicationRows(publicationSidebarProjection)
        : [],
    [publicationSidebarProjection],
  );
  const savedSources = useMemo(
    () =>
      savedFeedSources(
        usingSemble
          ? []
          : pathname.startsWith("/archive")
            ? archivedLinks
            : savedLinks,
        savedSidebarRows,
      ),
    [archivedLinks, pathname, savedLinks, savedSidebarRows, usingSemble],
  );
  const selectedSavedSource = searchParams.get("source");
  const selectedFolderRkey = searchParams.get("folder");
  const currentFeed = selectedListUri ? null : currentAppSidebarFeed({
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

  const listCreationPublications = useMemo(() => {
    const seen = new Set<string>();
    return publicationsForUnread
      .filter((publication) => {
        if (
          !/^at:\/\/did:[^/]+\/site\.standard\.publication\/[^/?#]+$/.test(publication.publicationId) ||
          seen.has(publication.publicationId)
        ) return false;
        seen.add(publication.publicationId);
        return true;
      })
      .map((publication) => ({
        publicationId: publication.publicationId,
        title: publication.title,
        authorDid: publication.authorDid,
        authorHandle: publication.authorHandle,
      }));
  }, [publicationsForUnread]);

  const publicationUnreadCounts = useSidebarUnreadController({
    publications: publicationsForUnread,
    unreadCountsByPublicationId: clientHydrated
      ? unreadCountsByPublicationId
      : SERVER_PUBLICATION_UNREAD_COUNTS,
    isEntryRead: clientHydrated ? isEntryRead : undefined,
    readEpoch,
    viewerDid: session?.did,
  });

  const setActiveReadFeedScope =
    useReadSidebarScopeOptional()?.setActiveFeedScope;

  useEffect(() => {
    if (!setActiveReadFeedScope) return;
    if (selectedListUri) {
      const displayName = readerLists.lists.find(list => list.uri === selectedListUri)?.name || "List";
      setActiveReadFeedScope(previous => previous.gatewayScope === null && previous.displayName === displayName && previous.publications.length === 0 ? previous : { publications: [], gatewayScope: null, displayName });
      return;
    }

    if (currentFeed === "wire" || currentFeed === "circle" || currentFeed === "finance" || currentFeed === "sports") {
      const displayName =
        currentFeed === "circle" ? "Your Circle" : currentFeed === "finance" ? "Finance" : currentFeed === "sports" ? "Sports" : "The Wire";
      setActiveReadFeedScope((previous) =>
        previous.gatewayScope === null &&
        previous.displayName === displayName &&
        previous.publications.length === 0
          ? previous
          : {
              publications: [],
              gatewayScope: null,
              displayName,
            },
      );
      return;
    }

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
    selectedListUri,
    readerLists.lists,
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
    if (
      !clientHydrated ||
      !bootstrapStreamComplete ||
      !wireNavigationEnabled ||
      !feedPreferences.showWire ||
      pathname !== "/read" ||
      searchParams.get("feed") ||
      searchParams.get("folder") ||
      searchParams.get("list") ||
      subscribedPublications.length > 0 ||
      followingTabPublications.length > 0
    ) {
      return;
    }
    const hasRememberedChoice =
      loadReaderFeedSelection(window.localStorage) !== null ||
      window.localStorage.getItem(SIDEBAR_PUBLICATION_TAB_STORAGE_KEY) !== null;
    if (!hasRememberedChoice) router.replace("/read?feed=wire");
  }, [
    bootstrapStreamComplete,
    clientHydrated,
    followingTabPublications.length,
    pathname,
    router,
    searchParams,
    subscribedPublications.length,
    wireNavigationEnabled,
    feedPreferences.showWire,
  ]);

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
    ? usingSemble
      ? (sembleItems.collection?.cardCount ?? sembleItems.items.length)
      : readLaterUnread
    : 0;
  const displayedArchiveUnread = showFeedCount("archive") ? archiveUnread : 0;
  const visible = new Set<ReaderNavigationFeed>(
    clientHydrated
      ? feedPreferences.visibleFeeds
      : DEFAULT_FEED_DISPLAY_PREFERENCES.visibleFeeds,
  );
  const displayPreferences = clientHydrated ? feedPreferences : DEFAULT_FEED_DISPLAY_PREFERENCES;
  if (displayPreferences.showWire) visible.add("wire");
  if (displayPreferences.showCircle) visible.add("circle");
  if (sportsTopicIsVisible(displayPreferences.showSports, { enabled: sportsCatalog.confirmedEnabled })) visible.add("sports");
  if (financeTopicIsVisible(displayPreferences.showFinance, financeCatalog.data)) visible.add("finance");

  if (podcastsEnabled()) visible.add("podcasts");

  const selectTopLevelFeed = (feed: ReaderNavigationFeed) => {
    if (feed === "podcasts") { setOpenMobile(false); router.push("/podcasts"); return; }
    setSelectedFolderUri(null);
    if (feed === "readLater") {
      router.push("/saved");
      return;
    }
    if (feed === "archive") {
      router.push(usingSemble ? "/saved" : "/archive");
      return;
    }
    if (feed === "sports") {
      saveReaderFeedSelection(window.localStorage, "sports");
      router.push("/read?feed=sports");
      return;
    }
    if (feed === "finance") {
      saveReaderFeedSelection(window.localStorage, "finance");
      router.push("/read?feed=finance");
      return;
    }
    if (feed === "wire") {
      saveReaderFeedSelection(window.localStorage, "wire");
      router.push("/read?feed=wire");
      return;
    }
    if (feed === "circle") {
      saveReaderFeedSelection(window.localStorage, "circle");
      router.push("/read?feed=circle");
      return;
    }
    setPublicationTab(feed);
    saveReaderFeedSelection(window.localStorage, feed);
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
      style={{
        left:
          "max(0px, calc((100vw - var(--reader-shell-width, 70rem)) / 2))",
      }}
    >
      <AppSidebarBrandHeader />

      <SidebarContent className="overflow-y-auto overflow-x-hidden">
        <div className="shrink-0">
          {visible.has("readLater") || visible.has("archive") ? (
          <SidebarGroup className="pb-1">
            <SidebarGroupLabel>
              {usingSemble
                ? configuredReadLater.sembleConnection?.collectionName || "Read Later"
                : "Read Later"}
            </SidebarGroupLabel>
            <SidebarMenu className="gap-0.5">
              {visible.has("readLater") ? <SidebarMenuItem>
                <SidebarMenuButton
                  type="button"
                  tooltip={
                    usingSemble
                      ? configuredReadLater.sembleConnection?.collectionName || "Semble Collection"
                      : "Read Later Links"
                  }
                  isActive={currentFeed === "readLater"}
                  onClick={() => selectTopLevelFeed("readLater")}
                  className={readLaterSidebarButtonClassName({
                    usingSemble,
                    count: displayedReadLaterUnread,
                  })}
                >
                  <Bookmark />
                  <span>
                    {usingSemble
                      ? configuredReadLater.sembleConnection?.collectionName || "Saved"
                      : "Saved"}
                  </span>
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
          <SidebarAudioSection enabled={podcastsEnabled()} active={currentFeed === "podcasts"} onSelect={() => selectTopLevelFeed("podcasts")} />
          <PublicationTabs
            visibleFeeds={visible}
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
            wireActive={currentFeed === "wire"}
            onWireSelect={() => selectTopLevelFeed("wire")}
            circleActive={currentFeed === "circle"}
            onCircleSelect={() => selectTopLevelFeed("circle")}
          />
          <SidebarTopicsSection
            visibleFeeds={visible}
            sportsEnabled={sportsCatalog.confirmedEnabled}
            sportsActive={currentFeed === "sports"}
            onSportsSelect={() => selectTopLevelFeed("sports")}
            financeActive={currentFeed === "finance"}
            onFinanceSelect={() => selectTopLevelFeed("finance")}
          />
          <SidebarListsSection
            key={session?.did || "signed-out"}
            lists={readerLists.lists}
            creatorResults={creatorResults}
            selectedUri={selectedListUri}
            loading={readerLists.signedIn && readerLists.query.isPending}
            searching={listsSearching}
            saving={readerLists.saving}
            error={readerLists.error instanceof Error ? readerLists.error.message : readerLists.error ? "Couldn't Load Lists." : null}
            onSelect={uri => { setOpenMobile(false); router.push(`/read?list=${encodeURIComponent(uri)}`); }}
            onSearchCreator={async creator => { const epoch = ++creatorSearchEpoch.current; setListsSearching(true); try { const results = await readerLists.searchCreator(creator); if (viewerDidRef.current === session?.did && epoch === creatorSearchEpoch.current) setCreatorResults(results); } finally { if (epoch === creatorSearchEpoch.current) setListsSearching(false); } }}
            onAdd={async input => { const list = await readerLists.resolveList(input); await readerLists.saveList(list.uri); }}
            onRemove={readerLists.removeList}
            onDelete={async (uri) => {
              const leaveDeletedList = () => {
                if (viewerDidRef.current === session?.did && selectedListUriRef.current === uri) {
                  router.push("/read");
                }
              };
              try {
                await readerLists.deleteList(uri);
              } catch (failure) {
                if ((failure as { originalDeleted?: boolean } | null)?.originalDeleted === true) leaveDeletedList();
                throw failure;
              }
              leaveDeletedList();
            }}
            onCreate={readerLists.createList}
            onResolveCreator={readerLists.resolveCreator}
            publications={listCreationPublications}
            onRefresh={readerLists.refresh}
          />
        </div>
        {showPublicationsRail && (selectedListUri || (
        currentFeed !== "wire" &&
        currentFeed !== "circle" && currentFeed !== "finance" && currentFeed !== "sports" && currentFeed !== "podcasts")) ? (
        <div className={`${floatingSidebarClassName} mx-2 flex flex-col self-stretch lg:self-start gap-0 group-data-[collapsible=icon]:overflow-hidden lg:fixed lg:mx-0 lg:right-[max(0.5rem,calc((100vw-var(--reader-shell-width,70rem))/2+0.5rem))] lg:top-[calc(var(--environment-banner-height,0px)+1rem)] lg:z-30 lg:w-60 lg:max-h-[calc(100svh-var(--environment-banner-height,0px)-2rem)] lg:overflow-y-auto lg:overscroll-contain`}>
          <div className="hidden shrink-0 items-center px-2 pb-2 lg:flex">
            <p className="text-base font-bold text-sidebar-foreground">
              Publications
            </p>
          </div>
          <SidebarGroup className="p-0">
            {!selectedListUri && currentFeed && currentFeed !== "wire" && currentFeed !== "circle" && currentFeed !== "finance" && currentFeed !== "sports" && currentFeed !== "podcasts" ? (
              <AllFeedSidebarButton
                feed={currentFeed}
                isActive={allFeedSelected}
                onSelect={selectTopLevelFeed}
              />
            ) : null}
            <SidebarMenu className="gap-1">
              {selectedListUri ? (
                <SidebarListPublicationsSection
                  list={selectedList.data}
                  loading={selectedList.isPending}
                  error={selectedList.error instanceof Error ? selectedList.error.message : null}
                  selectedPubId={selectedPubId}
                  onSelectPub={(publicationId) => { setOpenMobile(false); onSelectPub(publicationId); }}
                  onRetry={() => { void selectedList.refetch(); }}
                />
              ) : pathname.startsWith("/saved") ||
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
                  <p className="line-clamp-2 break-words text-sm font-medium leading-tight">
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
      listsActive={!!selectedListUri}
      onOpenLists={() => setOpenMobile(true)}
      visibleFeeds={visible}
      onSelect={selectTopLevelFeed}
      readLaterLabel={
        usingSemble
          ? configuredReadLater.sembleConnection?.collectionName || "Saved"
          : "Saved"
      }
    />
    </>
  );
}
