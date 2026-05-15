"use client";

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useRouter, usePathname } from "next/navigation";
import { LogOut, RefreshCw, Bookmark } from "lucide-react";
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
} from "@/components/ui/sidebar";
import { Avatar } from "@/components/shared/Avatar";
import { FolderBranch } from "./FolderBranch";
import { NewFolderDialog } from "./NewFolderDialog";
import { useAuth } from "@/hooks/useAuth";
import { useFolders } from "@/hooks/useFolders";
import {
  useDiscovery,
  usePublicationPrefs,
  usePublicationSubscriptions,
  useRefreshDiscovery,
} from "@/hooks/usePublications";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import {
  rkeyFromURI,
  type FolderRecord,
  type PublicationPrefsRecord,
  type RepoRecord,
} from "@/lib/pdsClient";
import {
  normalizeAtRepoParam,
  parseAtUri,
  type DiscoveredPublication,
  viewerOwnsDiscoveredPublication,
} from "@/lib/atprotoClient";
import { cn } from "@/lib/utils";
import { PublicationSubItem } from "./PublicationSubItem";

type PublicationTab = "subscribed" | "following";

interface AppSidebarProps {
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
}

export function AppSidebar({ selectedPubId, onSelectPub }: AppSidebarProps) {
  const router = useRouter();
  const pathname = usePathname();
  const { session, signOut } = useAuth();
  const [loggingOut, setLoggingOut] = useState(false);
  const { selectedFolderUri, setSelectedFolderUri } = useReadRoute();

  const [expandedKeys, setExpandedKeys] = useState(() => new Set<string>());
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

  const { data: folders = [], isLoading: foldersLoading } = useFolders();
  const { data: publications = [], isLoading: pubsLoading } = useDiscovery();
  const { data: prefs = [] } = usePublicationPrefs();
  const { data: subscriptions = [], isLoading: subscriptionsLoading } =
    usePublicationSubscriptions();
  const { data: profile, isLoading: profileLoading } = useViewerProfile();
  const refresh = useRefreshDiscovery();

  const prefsMap = useMemo(
    () => new Map(prefs.map((p) => [p.value.publicationId, p])),
    [prefs]
  );

  const visiblePubs = useMemo(
    () =>
      publications.filter((p) => {
        const pref = prefsMap.get(p.publicationId);
        return !pref?.value.hidden;
      }),
    [publications, prefsMap]
  );

  const viewerDid = session?.did;

  const subscriptionPublicationKeys = useMemo(() => {
    const keys = new Set<string>();
    for (const subscription of subscriptions) {
      addPublicationSubscriptionKey(keys, subscription.value.publication);
    }
    return keys;
  }, [subscriptions]);

  const isSubscribedPublication = useCallback(
    (pub: (typeof visiblePubs)[number]) =>
      publicationSubscriptionKeys(pub).some((key) =>
        subscriptionPublicationKeys.has(key)
      ),
    [subscriptionPublicationKeys]
  );

  const { subscribedPubs, followOwnedUnsubscribedPubs } = useMemo(() => {
    const subscribedPubs: typeof visiblePubs = [];
    const followOwnedUnsubscribedPubs: typeof visiblePubs = [];

    if (!viewerDid) {
      return { subscribedPubs, followOwnedUnsubscribedPubs };
    }

    for (const pub of visiblePubs) {
      if (viewerOwnsDiscoveredPublication(pub, viewerDid)) {
        subscribedPubs.push(pub);
      } else if (isSubscribedPublication(pub)) {
        subscribedPubs.push(pub);
      } else {
        followOwnedUnsubscribedPubs.push(pub);
      }
    }

    return { subscribedPubs, followOwnedUnsubscribedPubs };
  }, [visiblePubs, viewerDid, isSubscribedPublication]);

  const { folderMap, myPublications, unfolderedPubs } = useMemo(() => {
    const folderMap = new Map<string, typeof subscribedPubs>();
    const myPublications: typeof subscribedPubs = [];
    const unfolderedPubs: typeof subscribedPubs = [];

    for (const pub of subscribedPubs) {
      if (viewerOwnsDiscoveredPublication(pub, viewerDid)) {
        myPublications.push(pub);
        continue;
      }

      const pref = prefsMap.get(pub.publicationId);
      const folderId = pref?.value.folderId;
      if (folderId) {
        const list = folderMap.get(folderId) ?? [];
        list.push(pub);
        folderMap.set(folderId, list);
        continue;
      }

      unfolderedPubs.push(pub);
    }

    return { folderMap, myPublications, unfolderedPubs };
  }, [subscribedPubs, prefsMap, viewerDid]);

  const followingTabPublications = useMemo(() => {
    const myPublicationIds = new Set(myPublications.map((pub) => pub.publicationId));
    return followOwnedUnsubscribedPubs.filter(
      (pub) => !myPublicationIds.has(pub.publicationId)
    );
  }, [followOwnedUnsubscribedPubs, myPublications]);

  useEffect(() => {
    if (!selectedPubId) return;

    const pref = prefsMap.get(selectedPubId);
    const pub = publications.find((p) => p.publicationId === selectedPubId);
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
    publications,
    prefsMap,
    folders,
    setSelectedFolderUri,
  ]);

  useEffect(() => {
    if (!selectedPubId) return;

    let cancelled = false;
    queueMicrotask(() => {
      if (cancelled) return;
      setExpandedKeys((prev) => {
        const pref = prefsMap.get(selectedPubId);
        const pub = publications.find((p) => p.publicationId === selectedPubId);
        if (!pub) return prev;

        const folderId = pref?.value.folderId;
        if (!folderId) return prev;

        const folder = folders.find((f) => rkeyFromURI(f.uri) === folderId);
        if (!folder || prev.has(folder.uri)) return prev;

        const next = new Set(prev);
        next.add(folder.uri);
        return next;
      });
    });

    return () => {
      cancelled = true;
    };
  }, [selectedPubId, publications, prefsMap, folders]);

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
            size="icon"
            className="h-7 w-7 shrink-0"
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

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel>Read Later</SidebarGroupLabel>
          <SidebarMenu>
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
        <SidebarGroup>
          <SidebarMenu>
            {foldersLoading || pubsLoading || subscriptionsLoading ? (
              <SidebarSkeleton count={5} />
            ) : (
              <>
                <PublicationTabs
                  activeTab={publicationTab}
                  onTabChange={setPublicationTab}
                />
                {publicationTab === "subscribed" ? (
                  <>
                    <div className="h-1" aria-hidden />
                    <SidebarSectionLabel>Folders</SidebarSectionLabel>
                    {folders.map((f) => {
                      const rkey = rkeyFromURI(f.uri);
                      return (
                        <FolderBranch
                          key={f.uri}
                          expandKey={f.uri}
                          folder={f.value}
                          isActive={selectedFolderUri === f.uri}
                          expanded={expandedKeys.has(f.uri)}
                          onToggleExpanded={() => toggleExpanded(f.uri)}
                          publications={folderMap.get(rkey) ?? []}
                          emptyLabel="No publications in this folder."
                          selectedPubId={selectedPubId}
                          onSelectPub={onSelectPub}
                          folders={folders}
                          prefsMap={prefsMap}
                        />
                      );
                    })}
                    <NewFolderDialog />
                    <SidebarSectionLabel>Publications</SidebarSectionLabel>
                    <PublicationList
                      publications={unfolderedPubs}
                      emptyLabel="No subscribed publications outside folders."
                      selectedPubId={selectedPubId}
                      onSelectPub={onSelectPub}
                      folders={folders}
                      prefsMap={prefsMap}
                    />
                    <SidebarSectionLabel>My Publications</SidebarSectionLabel>
                    <PublicationList
                      publications={myPublications}
                      emptyLabel="No publications on your account discovered yet."
                      selectedPubId={selectedPubId}
                      onSelectPub={onSelectPub}
                      folders={folders}
                      prefsMap={prefsMap}
                    />
                  </>
                ) : (
                  <>
                    <SidebarSectionLabel>Publications</SidebarSectionLabel>
                    <PublicationList
                      publications={followingTabPublications}
                      emptyLabel="No unsubscribed publications from followed accounts."
                      selectedPubId={selectedPubId}
                      onSelectPub={onSelectPub}
                      folders={folders}
                      prefsMap={prefsMap}
                    />
                  </>
                )}
              </>
            )}
          </SidebarMenu>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter className="border-t px-2 py-3">
        <div className="flex min-w-0 items-start gap-3 px-2 pb-2">
          {profileLoading ? (
            <div className="flex min-w-0 flex-1 items-start gap-3">
              <Skeleton className="size-10 shrink-0 rounded-full" />
              <div className="flex min-w-0 flex-1 flex-col gap-1.5 pt-0.5">
                <Skeleton className="h-4 w-28" />
                <Skeleton className="h-3 w-full max-w-[12rem]" />
              </div>
            </div>
          ) : (
            <>
              <Avatar
                src={profile?.avatar}
                alt={profile?.displayName || profile?.handle || session?.did || "Account"}
                size={40}
                className="shrink-0"
              />
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-medium leading-tight text-sidebar-foreground">
                  {profile?.displayName?.trim() ||
                    profile?.handle ||
                    session?.did ||
                    "—"}
                </p>
                <p className="truncate text-[11px] leading-tight text-muted-foreground">
                  {session?.did ?? ""}
                </p>
              </div>
            </>
          )}
        </div>
        <SidebarMenu>
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
        className="grid grid-cols-2 gap-0.5 rounded-md bg-sidebar-accent/50 p-0.5"
        role="tablist"
        aria-label="Publication source"
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
        "min-w-0 rounded px-2 py-1.5 text-center text-xs font-medium transition-colors",
        active
          ? "bg-sidebar text-sidebar-foreground shadow-sm"
          : "text-muted-foreground hover:text-sidebar-foreground"
      )}
    >
      <span className="block truncate">{children}</span>
    </button>
  );
}

function SidebarSectionLabel({ children }: { children: ReactNode }) {
  return (
    <SidebarMenuItem>
      <div className="px-2 pt-2 pb-1 text-xs font-medium text-sidebar-foreground/70">
        {children}
      </div>
    </SidebarMenuItem>
  );
}

function PublicationList({
  publications,
  emptyLabel,
  selectedPubId,
  onSelectPub,
  folders,
  prefsMap,
}: {
  publications: DiscoveredPublication[];
  emptyLabel: string;
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
  folders: RepoRecord<FolderRecord>[];
  prefsMap: Map<string, RepoRecord<PublicationPrefsRecord>>;
}) {
  if (publications.length === 0) {
    return (
      <SidebarMenuSubItem>
        <span className="block min-w-0 break-words px-2 py-1 text-xs text-muted-foreground">
          {emptyLabel}
        </span>
      </SidebarMenuSubItem>
    );
  }

  return (
    <SidebarMenuSub
      className="mx-0 translate-x-0 border-l-0 px-0"
      aria-label="Following publications"
    >
      {publications.map((pub) => (
        <PublicationSubItem
          key={pub.publicationId}
          publication={pub}
          isSelected={selectedPubId === pub.publicationId}
          onSelect={onSelectPub}
          folders={folders}
          prefsMap={prefsMap}
        />
      ))}
    </SidebarMenuSub>
  );
}

function publicationSubscriptionKeys(pub: DiscoveredPublication): string[] {
  const keys = new Set<string>();
  addPublicationSubscriptionKey(keys, pub.subscriptionPublicationId);
  addPublicationSubscriptionKey(keys, pub.publicationId);
  return [...keys];
}

function addPublicationSubscriptionKey(keys: Set<string>, value: string | undefined) {
  if (!value) return;
  const normalized = normalizeAtRepoParam(value);

  // Bare DID — subscriptions and content-only publications both key by DID.
  if (normalized.startsWith("did:")) {
    keys.add(normalized);
    return;
  }

  const parsed = parseAtUri(normalized);
  if (!parsed) return;

  keys.add(normalized);
  // Index the author DID so subscriptions stored as AT-URIs match
  // content-only follows whose publicationId is just the DID.
  keys.add(parsed.did);
  // Cross-collection alias: site.standard.publication ↔ com.standard.publication
  if (parsed.collection === "site.standard.publication") {
    keys.add(`at://${parsed.did}/com.standard.publication/${parsed.rkey}`);
  } else if (parsed.collection === "com.standard.publication") {
    keys.add(`at://${parsed.did}/site.standard.publication/${parsed.rkey}`);
  }
}

function SidebarSkeleton({ count }: { count: number }) {
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <SidebarMenuItem key={i}>
          <Skeleton className="h-8 w-full rounded-md" />
        </SidebarMenuItem>
      ))}
    </>
  );
}
