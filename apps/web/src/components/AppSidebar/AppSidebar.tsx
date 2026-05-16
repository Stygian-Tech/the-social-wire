"use client";

import Link from "next/link";
import { useCallback, useEffect, useId, useMemo, useState, type ReactNode } from "react";
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
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
  SidebarMenuSubItem,
  SidebarResizeHandle,
  SIDEBAR_GLASS_ICON,
  SIDEBAR_GLASS_SEGMENTED,
} from "@/components/ui/sidebar";
import { Avatar } from "@/components/shared/Avatar";
import { FolderBranch } from "./FolderBranch";
import { NewFolderDialog } from "./NewFolderDialog";
import { AddPublicationDialog } from "./AddPublicationDialog";
import { useAuth } from "@/hooks/useAuth";
import { usePrefetchSidebarPublicationEntries } from "@/hooks/usePrefetchSidebarPublicationEntries";
import { usePublicationSidebarData } from "@/hooks/usePublicationSidebarData";
import { useSidebarUnreadCounts } from "@/hooks/useSidebarUnreadCounts";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useReadSidebarScopeOptional } from "@/contexts/ReadSidebarScopeContext";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import {
  rkeyFromURI,
  type FolderRecord,
  type PublicationPrefsRecord,
  type RepoRecord,
} from "@/lib/pdsClient";
import { type DiscoveredPublication, viewerOwnsDiscoveredPublication } from "@/lib/atprotoClient";
import { sumUnreadForPublications } from "@/lib/unreadCounts";
import { cn } from "@/lib/utils";
import {
  PublicationSubItem,
  type PublicationSidebarTab,
} from "./PublicationSubItem";
import { SidebarReadBulkMenuWrap } from "./SidebarReadBulkMenuWrap";

type PublicationTab = "subscribed" | "following";

const SIDEBAR_SEC_FOLDERS = "__sidebar_sec:folders";
const SIDEBAR_SEC_PUBLICATIONS = "__sidebar_sec:publications";

interface AppSidebarProps {
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
}

export function AppSidebar({ selectedPubId, onSelectPub }: AppSidebarProps) {
  const router = useRouter();
  const pathname = usePathname();
  const { session, signOut } = useAuth();
  const [loggingOut, setLoggingOut] = useState(false);
  const { selectedFolderUri, setSelectedFolderUri, isEntryRead } = useReadRoute();

  const [expandedKeys, setExpandedKeys] = useState(
    () => new Set<string>([SIDEBAR_SEC_FOLDERS, SIDEBAR_SEC_PUBLICATIONS])
  );
  const [publicationTab, setPublicationTab] =
    useState<PublicationTab>("subscribed");

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
      router.replace("/login");
    } catch (err) {
      console.error(err);
    } finally {
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
    sidebarListsLoading,
    refresh,
    viewerDid,
  } = usePublicationSidebarData();
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

  usePrefetchSidebarPublicationEntries(
    publicationsForUnread,
    !sidebarListsLoading && !!session
  );

  const publicationUnreadCounts = useSidebarUnreadCounts(
    publicationsForUnread,
    isEntryRead
  );

  const readSidebarScope = useReadSidebarScopeOptional();

  useEffect(() => {
    readSidebarScope?.setPublicationsInSidebarTab(publicationsForUnread);
  }, [readSidebarScope, publicationsForUnread]);

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
              Alpha
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
          {!sidebarListsLoading ? (
            <SidebarGroup className="pt-0">
              <SidebarMenu className="gap-1.5">
                <PublicationTabs
                  activeTab={publicationTab}
                  onTabChange={setPublicationTab}
                />
              </SidebarMenu>
            </SidebarGroup>
          ) : null}
        </div>
        <div className="no-scrollbar flex min-h-0 min-w-0 flex-1 flex-col gap-0 overflow-y-auto overflow-x-hidden group-data-[collapsible=icon]:overflow-hidden">
          <SidebarGroup className="px-2 pb-2 pt-4">
            <SidebarMenu className="gap-4">
              {sidebarListsLoading ? (
                <SidebarSkeleton count={5} />
              ) : publicationTab === "subscribed" ? (
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
                        {folders.map((f) => {
                          const rkey = rkeyFromURI(f.uri);
                          return (
                            <FolderBranch
                              key={f.uri}
                              expandKey={f.uri}
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
                            />
                          );
                        })}
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
                    />
                    <SidebarMenuSubItem className="p-0">
                      <AddPublicationDialog />
                    </SidebarMenuSubItem>
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
                    />
                    <SidebarMenuSubItem className="p-0">
                      <AddPublicationDialog />
                    </SidebarMenuSubItem>
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

function UnreadSidebarBadge({ count }: { count: number }) {
  if (count <= 0) return null;
  const label = String(count);
  return (
    <SidebarMenuBadge aria-label={`${label} unread`}>{label}</SidebarMenuBadge>
  );
}

function PublicationTabs({
  activeTab,
  onTabChange,
}: {
  activeTab: PublicationTab;
  onTabChange: (tab: PublicationTab) => void;
}) {
  return (
    <SidebarMenuItem>
      <div
        className={cn(SIDEBAR_GLASS_SEGMENTED)}
        role="tablist"
        aria-label="Publication Source"
      >
        <PublicationTabButton
          active={activeTab === "subscribed"}
          onClick={() => onTabChange("subscribed")}
        >
          Subscribed
        </PublicationTabButton>
        <PublicationTabButton
          active={activeTab === "following"}
          onClick={() => onTabChange("following")}
        >
          Following
        </PublicationTabButton>
      </div>
    </SidebarMenuItem>
  );
}

function PublicationTabButton({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      role="tab"
      aria-selected={active}
      onClick={onClick}
      className={cn(
        "flex h-8 min-h-8 min-w-0 items-center justify-center rounded-lg px-3 py-0 text-center text-xs font-medium transition-[background-color,border-color,box-shadow,color] backdrop-blur-sm hover:[box-shadow:var(--purple-glow-hover)] active:[box-shadow:var(--purple-glow-selected)]",
        active
          ? "border-sidebar-border/80 bg-sidebar font-semibold text-sidebar-foreground shadow-inner dark:border-sidebar-border dark:bg-sidebar-accent/90 dark:text-sidebar-accent-foreground"
          : "border border-transparent bg-transparent text-muted-foreground hover:border-sidebar-border/55 hover:bg-sidebar-accent/50 hover:text-sidebar-foreground dark:hover:bg-sidebar-accent/38"
      )}
    >
      <span className="block truncate">{children}</span>
    </button>
  );
}

function CollapsibleSidebarSubSection({
  title,
  unreadCount = 0,
  expanded,
  onToggle,
  subAriaLabel,
  readBulkPublications,
  readBulkMarkAllReadConfirmation,
  children,
}: {
  title: string;
  unreadCount?: number;
  expanded: boolean;
  onToggle: () => void;
  subAriaLabel: string;
  readBulkPublications?: DiscoveredPublication[];
  /** Required when `readBulkPublications` is provided */
  readBulkMarkAllReadConfirmation?: ReactNode;
  children: ReactNode;
}) {
  const subId = `sidebar-collapsible-sub-${useId().replace(/:/g, "")}`;

  const toggleButton = (
    <SidebarMenuButton
      type="button"
      onClick={onToggle}
      aria-expanded={expanded}
      aria-controls={subId}
      className={cn("gap-2", unreadCount > 0 && "relative pr-8")}
    >
      <ChevronRight
        className={cn(
          "size-4 shrink-0 transition-transform",
          expanded && "rotate-90"
        )}
        aria-hidden
      />
      <span className="min-w-0 flex-1 truncate text-left text-xs font-medium">
        {title}
      </span>
      <UnreadSidebarBadge count={unreadCount} />
    </SidebarMenuButton>
  );

  return (
    <SidebarMenuItem>
      {readBulkPublications !== undefined &&
      readBulkMarkAllReadConfirmation !== undefined ? (
        <SidebarReadBulkMenuWrap
          publications={readBulkPublications}
          markAllReadConfirmation={readBulkMarkAllReadConfirmation}
        >
          {toggleButton}
        </SidebarReadBulkMenuWrap>
      ) : (
        toggleButton
      )}
      {expanded ? (
        <SidebarMenuSub
          id={subId}
          aria-label={subAriaLabel}
          className="mt-1.5"
        >
          {children}
        </SidebarMenuSub>
      ) : null}
    </SidebarMenuItem>
  );
}

function PublicationMenuSubEntries({
  publications,
  publicationUnreadCounts,
  selectedPubId,
  onSelectPub,
  folders,
  prefsMap,
  sidebarTab,
}: {
  publications: DiscoveredPublication[];
  publicationUnreadCounts: Map<string, number>;
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
  folders: RepoRecord<FolderRecord>[];
  prefsMap: Map<string, RepoRecord<PublicationPrefsRecord>>;
  sidebarTab: PublicationSidebarTab;
}) {
  if (publications.length === 0) {
    return null;
  }

  return (
    <>
      {publications.map((pub) => (
        <PublicationSubItem
          key={pub.publicationId}
          publication={pub}
          unreadCount={publicationUnreadCounts.get(pub.publicationId) ?? 0}
          isSelected={selectedPubId === pub.publicationId}
          onSelect={onSelectPub}
          folders={folders}
          prefsMap={prefsMap}
          sidebarTab={sidebarTab}
        />
      ))}
    </>
  );
}

function SidebarSkeleton({ count }: { count: number }) {
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <SidebarMenuItem key={i}>
          <Skeleton className="h-9 w-full rounded-lg" />
        </SidebarMenuItem>
      ))}
    </>
  );
}
