"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useRouter, usePathname } from "next/navigation";
import { ChevronRight, LogOut, RefreshCw, Bookmark } from "lucide-react";
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
  SidebarMenuSub,
  SidebarMenuSubItem,
  SidebarResizeHandle,
  SIDEBAR_GLASS_ICON,
} from "@/components/ui/sidebar";
import { Avatar } from "@/components/shared/Avatar";
import { FolderBranch } from "./FolderBranch";
import { NewFolderDialog } from "./NewFolderDialog";
import { AddPublicationDialog } from "./AddPublicationDialog";
import { useAuth } from "@/hooks/useAuth";
import { usePublicationSidebarData } from "@/hooks/usePublicationSidebarData";
import { usePrefetchSidebarPublicationEntries } from "@/hooks/usePrefetchSidebarPublicationEntries";
import { normalizeAtRepoParam } from "@/lib/atprotoClient";
import { useSidebarUnreadCounts } from "@/hooks/useSidebarUnreadCounts";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useReadSidebarScopeOptional } from "@/contexts/ReadSidebarScopeContext";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import { rkeyFromURI } from "@/lib/pdsClient";
import { type DiscoveredPublication, viewerOwnsDiscoveredPublication } from "@/lib/atprotoClient";
import { sumUnreadForPublications } from "@/lib/unreadCounts";
import { cn } from "@/lib/utils";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";
import {
  SIDEBAR_SEC_FOLDERS,
  SIDEBAR_SEC_PUBLICATIONS,
} from "./appSidebarConstants";
import { CollapsibleSidebarSubSection } from "./CollapsibleSidebarSubSection";
import { PublicationMenuSubEntries } from "./PublicationMenuSubEntries";
import { PublicationTabs } from "./PublicationTabs";
import { SidebarSubMenuSkeletonRows } from "./SidebarSubMenuSkeletonRows";
import { UnreadSidebarBadge } from "./UnreadSidebarBadge";

interface AppSidebarProps {
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
}

export function AppSidebar({ selectedPubId, onSelectPub }: AppSidebarProps) {
  const router = useRouter();
  const pathname = usePathname();
  const { session, signOut } = useAuth();
  const [loggingOut, setLoggingOut] = useState(false);
  const { selectedFolderUri, setSelectedFolderUri, publicationTab, setPublicationTab } =
    useReadRoute();

  const [expandedKeys, setExpandedKeys] = useState(
    () => new Set<string>([SIDEBAR_SEC_FOLDERS, SIDEBAR_SEC_PUBLICATIONS])
  );

  const toggleExpanded = useCallback((key: string) => {
    setExpandedKeys((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }, []);

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
    refresh,
    viewerDid,
    unreadCountsByPublicationId,
    folderPublicationsLoading,
    foldersListLoading,
    subscribedPublicationsLoading,
    followingPublicationsLoading,
    streamSelectedPublicationId,
    hasSidebarSnapshot,
  } = usePublicationSidebarData();

  usePrefetchSidebarPublicationEntries(
    allPublicationRows,
    hasSidebarSnapshot && !!session,
    selectedPubId ?? streamSelectedPublicationId
  );

  const autoSelectRef = useRef<string | null>(null);

  useEffect(() => {
    if (pathname !== "/read") return;
    if (!streamSelectedPublicationId) return;
    const normalized = normalizeAtRepoParam(streamSelectedPublicationId);
    if (autoSelectRef.current === normalized) return;
    autoSelectRef.current = normalized;
    router.replace(`/read/${encodeURIComponent(normalized)}`);
  }, [pathname, router, streamSelectedPublicationId]);
  const { data: profile, isLoading: profileLoading } = useViewerProfile();

  const publicationsForUnread = useMemo(() => {
    if (publicationTab !== "subscribed") {
      return followingTabPublications;
    }
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
  }, [publicationTab, folders, folderMap, unfolderedPubs, followingTabPublications]);

  const publicationUnreadCounts = useSidebarUnreadCounts(
    publicationsForUnread,
    unreadCountsByPublicationId
  );

  const setPublicationsInReadShell =
    useReadSidebarScopeOptional()?.setPublicationsInSidebarTab;

  useEffect(() => {
    if (!setPublicationsInReadShell) return;
    setPublicationsInReadShell((prev) => {
      if (
        prev.length === publicationsForUnread.length &&
        prev.every(
          (p, i) => p.publicationId === publicationsForUnread[i]?.publicationId
        )
      ) {
        return prev;
      }
      return publicationsForUnread;
    });
  }, [publicationsForUnread, setPublicationsInReadShell]);

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

  const foldersSectionUnread = useMemo(() => {
    if (publicationTab !== "subscribed") return 0;
    return folders.reduce((acc, f) => {
      const rkey = rkeyFromURI(f.uri);
      const pubs = folderMap.get(rkey) ?? [];
      return acc + sumUnreadForPublications(pubs, publicationUnreadCounts);
    }, 0);
  }, [publicationTab, folders, folderMap, publicationUnreadCounts]);

  const publicationsSectionUnread = useMemo(() => {
    if (publicationTab === "subscribed") {
      return sumUnreadForPublications(unfolderedPubs, publicationUnreadCounts);
    }
    return sumUnreadForPublications(
      followingTabPublications,
      publicationUnreadCounts
    );
  }, [
    publicationTab,
    unfolderedPubs,
    followingTabPublications,
    publicationUnreadCounts,
  ]);

  const selectionExpandedKeys = useMemo(() => {
    const next = new Set<string>();
    if (!selectedPubId) return next;

    const pref = prefsMap.get(selectedPubId);
    const pub = allPublicationRows.find((p) => p.publicationId === selectedPubId);
    if (!pub) return next;

    const folderId = pref?.value.folderId;
    if (folderId) {
      const folder = folders.find((f) => rkeyFromURI(f.uri) === folderId);
      if (folder) {
        next.add(folder.uri);
        next.add(SIDEBAR_SEC_FOLDERS);
      }
    } else if (!viewerDid || !viewerOwnsDiscoveredPublication(pub, viewerDid)) {
      next.add(SIDEBAR_SEC_PUBLICATIONS);
    }

    return next;
  }, [selectedPubId, allPublicationRows, prefsMap, folders, viewerDid]);

  const effectiveExpandedKeys = useMemo(() => {
    const merged = new Set(expandedKeys);
    for (const k of selectionExpandedKeys) merged.add(k);
    return merged;
  }, [expandedKeys, selectionExpandedKeys]);

  useEffect(() => {
    if (!selectedPubId) return;

    const pref = prefsMap.get(selectedPubId);
    const pub = allPublicationRows.find((p) => p.publicationId === selectedPubId);
    if (!pub) return;

    const folderId = pref?.value.folderId;
    if (folderId) {
      const folder = folders.find((f) => rkeyFromURI(f.uri) === folderId);
      if (folder) {
        setSelectedFolderUri(folder.uri);
        return;
      }
    }

    setSelectedFolderUri(null);
  }, [
    selectedPubId,
    allPublicationRows,
    prefsMap,
    folders,
    setSelectedFolderUri,
  ]);

  return (
    <Sidebar>
      <SidebarHeader className="border-b px-4 py-3">
        <div className="flex min-w-0 items-center justify-between gap-2">
          <div className="flex min-w-0 flex-col gap-0.5">
            <span className="truncate font-semibold text-sm">The Social Wire</span>
            <span className="inline-flex w-fit items-center rounded-full border px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground">
              Beta
            </span>
          </div>
          <Button
            variant="ghost"
            size="icon-sm"
            className={cn(SIDEBAR_GLASS_ICON, "size-8 shrink-0")}
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

      <SidebarContent className="overflow-hidden">
        <div className="shrink-0 border-b border-sidebar-border bg-sidebar">
          <SidebarGroup>
            <SidebarGroupLabel>Read Later</SidebarGroupLabel>
            <SidebarMenu className="gap-1.5">
              <SidebarMenuItem>
                <SidebarMenuButton
                  type="button"
                  tooltip="Read Later Links"
                  isActive={pathname.startsWith("/saved")}
                  onClick={() => router.push("/saved")}
                >
                  <Bookmark />
                  <span>Saved</span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            </SidebarMenu>
          </SidebarGroup>
          <SidebarGroup className="pt-0">
            <SidebarMenu className="gap-1.5">
              <PublicationTabs
                activeTab={publicationTab}
                onTabChange={setPublicationTab}
              />
            </SidebarMenu>
          </SidebarGroup>
        </div>
        <div className="no-scrollbar flex min-h-0 min-w-0 flex-1 flex-col gap-0 overflow-y-auto overflow-x-hidden group-data-[collapsible=icon]:overflow-hidden">
          <SidebarGroup className="px-2 pb-2 pt-4">
            <SidebarMenu className="gap-4">
              {publicationTab === "subscribed" ? (
                <>
                  <SidebarMenuItem>
                    <SidebarReadBulkMenuWrap
                      publications={allFolderedPublicationsForBulk}
                      markAllReadConfirmation={
                        <>
                          This marks every cached article across all folders as read.
                          Entries that have not been loaded yet stay unchanged until you open
                          them.
                        </>
                      }
                    >
                      <SidebarMenuButton
                        type="button"
                        onClick={() => toggleExpanded(SIDEBAR_SEC_FOLDERS)}
                        aria-expanded={effectiveExpandedKeys.has(SIDEBAR_SEC_FOLDERS)}
                        className={cn(
                          "gap-2",
                          foldersSectionUnread > 0 && "relative pr-8"
                        )}
                      >
                        <ChevronRight
                          className={cn(
                            "size-4 shrink-0 transition-transform",
                            effectiveExpandedKeys.has(SIDEBAR_SEC_FOLDERS) && "rotate-90"
                          )}
                          aria-hidden
                        />
                        <span className="min-w-0 flex-1 truncate text-left text-xs font-medium">
                          Folders
                        </span>
                        <UnreadSidebarBadge count={foldersSectionUnread} />
                      </SidebarMenuButton>
                    </SidebarReadBulkMenuWrap>
                    {effectiveExpandedKeys.has(SIDEBAR_SEC_FOLDERS) ? (
                      <SidebarMenuSub
                        aria-label="Folders"
                        className="mt-1.5"
                      >
                        {foldersListLoading ? (
                          <SidebarSubMenuSkeletonRows count={2} />
                        ) : (
                          folders.map((f) => {
                            const rkey = rkeyFromURI(f.uri);
                            return (
                              <FolderBranch
                                key={f.uri}
                                expandKey={f.uri}
                                folderUri={f.uri}
                                folder={f.value}
                                isActive={selectedFolderUri === f.uri}
                                expanded={effectiveExpandedKeys.has(f.uri)}
                                onToggleExpanded={() => toggleExpanded(f.uri)}
                                publications={folderMap.get(rkey) ?? []}
                                emptyLabel="No publications in this folder."
                                selectedPubId={selectedPubId}
                                onSelectPub={onSelectPub}
                                folders={folders}
                                prefsMap={prefsMap}
                                sidebarTab="subscribed"
                                publicationUnreadCounts={publicationUnreadCounts}
                                publicationsLoading={folderPublicationsLoading}
                              />
                            );
                          })
                        )}
                        <SidebarMenuItem>
                          <NewFolderDialog />
                        </SidebarMenuItem>
                      </SidebarMenuSub>
                    ) : null}
                  </SidebarMenuItem>
                  <CollapsibleSidebarSubSection
                    title="Publications"
                    unreadCount={publicationsSectionUnread}
                    expanded={effectiveExpandedKeys.has(SIDEBAR_SEC_PUBLICATIONS)}
                    onToggle={() => toggleExpanded(SIDEBAR_SEC_PUBLICATIONS)}
                    subAriaLabel="Subscribed Publications"
                    readBulkPublications={unfolderedPubs}
                    readBulkMarkAllReadConfirmation={
                      <>
                        This marks every cached article in Publications (sources not in a
                        folder) as read. Entries that have not been loaded yet stay unchanged
                        until you open them.
                      </>
                    }
                  >
                    <PublicationMenuSubEntries
                      publications={unfolderedPubs}
                      publicationUnreadCounts={publicationUnreadCounts}
                      selectedPubId={selectedPubId}
                      onSelectPub={onSelectPub}
                      folders={folders}
                      prefsMap={prefsMap}
                      sidebarTab="subscribed"
                      listLoading={subscribedPublicationsLoading}
                    />
                    {!subscribedPublicationsLoading ? (
                      <SidebarMenuSubItem className="p-0">
                        <AddPublicationDialog />
                      </SidebarMenuSubItem>
                    ) : null}
                  </CollapsibleSidebarSubSection>
                </>
              ) : (
                <>
                  <CollapsibleSidebarSubSection
                    title="Publications"
                    unreadCount={publicationsSectionUnread}
                    expanded={effectiveExpandedKeys.has(SIDEBAR_SEC_PUBLICATIONS)}
                    onToggle={() => toggleExpanded(SIDEBAR_SEC_PUBLICATIONS)}
                    subAriaLabel="Publications From Followed Accounts"
                    readBulkPublications={followingTabPublications}
                    readBulkMarkAllReadConfirmation={
                      <>
                        This marks every cached article from publications you follow as read.
                        Entries that have not been loaded yet stay unchanged until you open
                        them.
                      </>
                    }
                  >
                    <PublicationMenuSubEntries
                      publications={followingTabPublications}
                      publicationUnreadCounts={publicationUnreadCounts}
                      selectedPubId={selectedPubId}
                      onSelectPub={onSelectPub}
                      folders={folders}
                      prefsMap={prefsMap}
                      sidebarTab="following"
                      listLoading={followingPublicationsLoading}
                    />
                    {!followingPublicationsLoading ? (
                      <SidebarMenuSubItem className="p-0">
                        <AddPublicationDialog />
                      </SidebarMenuSubItem>
                    ) : null}
                  </CollapsibleSidebarSubSection>
                </>
              )}
            </SidebarMenu>
          </SidebarGroup>
        </div>
      </SidebarContent>

      <SidebarFooter className="border-t px-2 py-3">
        <SidebarMenu className="gap-2 px-2">
          {profileLoading ? (
            <SidebarMenuItem>
              <div className="flex min-w-0 flex-1 items-start gap-3 px-2 py-1">
                <Skeleton className="size-10 shrink-0 rounded-full" />
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
                render={<Link href="/me/publications" prefetch />}
                className="h-auto min-h-0 items-start gap-3 overflow-visible py-2.5 whitespace-normal"
              >
                <Avatar
                  src={profile?.avatar}
                  alt={profile?.displayName || profile?.handle || session?.did || "Account"}
                  size={40}
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
                    {session?.did ?? ""}
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
