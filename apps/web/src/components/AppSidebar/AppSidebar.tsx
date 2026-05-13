"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { LogOut, RefreshCw } from "lucide-react";
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
import { Label } from "@/components/ui/label";
import { FolderBranch } from "./FolderBranch";
import { NewFolderDialog } from "./NewFolderDialog";
import { useAuth } from "@/hooks/useAuth";
import { useFolders } from "@/hooks/useFolders";
import {
  useDiscovery,
  usePublicationPrefs,
  useRefreshDiscovery,
} from "@/hooks/usePublications";
import { useShowHiddenFolder } from "@/hooks/useShowHiddenFolder";
import { useReadRoute } from "@/contexts/ReadRouteContext";
import { useViewerProfile } from "@/hooks/useViewerProfile";
import {
  PSEUDO_FOLDER_HIDDEN_URI,
  PSEUDO_FOLDER_MY_URI,
  rkeyFromURI,
} from "@/lib/pdsClient";
import { viewerOwnsDiscoveredPublication } from "@/lib/atprotoClient";

const ALL_BRANCH_KEY = "__all__";

interface AppSidebarProps {
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
}

export function AppSidebar({ selectedPubId, onSelectPub }: AppSidebarProps) {
  const router = useRouter();
  const { session, signOut } = useAuth();
  const [loggingOut, setLoggingOut] = useState(false);
  const { selectedFolderUri, setSelectedFolderUri } = useReadRoute();

  const [expandedKeys, setExpandedKeys] = useState(
    () => new Set<string>([ALL_BRANCH_KEY])
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
  const { data: profile, isLoading: profileLoading } = useViewerProfile();
  const refresh = useRefreshDiscovery();
  const { showHiddenFolder, setShowHiddenFolder } = useShowHiddenFolder();

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

  const hiddenPubs = useMemo(
    () =>
      publications.filter((p) => {
        const pref = prefsMap.get(p.publicationId);
        return !!pref?.value.hidden;
      }),
    [publications, prefsMap]
  );

  const viewerDid = session?.did;

  useEffect(() => {
    if (!viewerDid && selectedFolderUri === PSEUDO_FOLDER_MY_URI) {
      setSelectedFolderUri(null);
    }
  }, [viewerDid, selectedFolderUri, setSelectedFolderUri]);

  // One bucket per visible pub: folder (folderId) wins over My; else My if on viewer repo; else All.
  const { folderMap, unfolderedPubs, myPublications } = useMemo(() => {
    const folderMap = new Map<string, typeof visiblePubs>();
    const unfolderedPubs: typeof visiblePubs = [];
    const myPublications: typeof visiblePubs = [];

    for (const pub of visiblePubs) {
      const pref = prefsMap.get(pub.publicationId);
      const folderId = pref?.value.folderId;
      if (folderId) {
        const list = folderMap.get(folderId) ?? [];
        list.push(pub);
        folderMap.set(folderId, list);
        continue;
      }

      if (viewerOwnsDiscoveredPublication(pub, viewerDid)) {
        myPublications.push(pub);
      } else {
        unfolderedPubs.push(pub);
      }
    }

    return { folderMap, unfolderedPubs, myPublications };
  }, [visiblePubs, prefsMap, viewerDid]);

  useEffect(() => {
    if (!selectedPubId) return;

    const pref = prefsMap.get(selectedPubId);
    if (pref?.value.hidden) {
      setSelectedFolderUri(PSEUDO_FOLDER_HIDDEN_URI);
      return;
    }

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

    if (viewerOwnsDiscoveredPublication(pub, viewerDid)) {
      setSelectedFolderUri(PSEUDO_FOLDER_MY_URI);
      return;
    }

    setSelectedFolderUri(null);
  }, [
    selectedPubId,
    publications,
    prefsMap,
    folders,
    viewerDid,
    setSelectedFolderUri,
  ]);

  useEffect(() => {
    if (!selectedPubId) return;

    setExpandedKeys((prev) => {
      const next = new Set(prev);

      const pref = prefsMap.get(selectedPubId);
      if (pref?.value.hidden) {
        next.add(PSEUDO_FOLDER_HIDDEN_URI);
        return next;
      }

      const pub = publications.find((p) => p.publicationId === selectedPubId);
      if (!pub) return next;

      const folderId = pref?.value.folderId;
      let expandedAssignedFolder = false;
      if (folderId) {
        const folder = folders.find((f) => rkeyFromURI(f.uri) === folderId);
        if (folder) {
          next.add(folder.uri);
          expandedAssignedFolder = true;
        }
      }

      if (!expandedAssignedFolder && viewerOwnsDiscoveredPublication(pub, viewerDid)) {
        next.add(PSEUDO_FOLDER_MY_URI);
      }

      if (!folderId && !viewerOwnsDiscoveredPublication(pub, viewerDid)) {
        next.add(ALL_BRANCH_KEY);
      }

      return next;
    });
  }, [selectedPubId, publications, prefsMap, folders, viewerDid]);

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
            title="Refresh publications"
          >
            <RefreshCw
              className={`h-3.5 w-3.5 ${refresh.isPending ? "animate-spin" : ""}`}
            />
          </Button>
        </div>
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel>Folders & publications</SidebarGroupLabel>
          <SidebarMenu>
            {foldersLoading || pubsLoading ? (
              <SidebarSkeleton count={5} />
            ) : (
              <>
                <FolderBranch
                  expandKey={ALL_BRANCH_KEY}
                  folder={{
                    name: "All Publications",
                    icon: undefined,
                    iconImage: undefined,
                  }}
                  isActive={selectedFolderUri === null}
                  expanded={expandedKeys.has(ALL_BRANCH_KEY)}
                  onToggleExpanded={() => toggleExpanded(ALL_BRANCH_KEY)}
                  publications={unfolderedPubs}
                  emptyLabel="No unfoldered publications. Follow feeds or assign items to a folder."
                  selectedPubId={selectedPubId}
                  onSelectPub={onSelectPub}
                  folders={folders}
                  prefsMap={prefsMap}
                  nameSuffix="unfoldered"
                />
                {viewerDid ? (
                  <FolderBranch
                    expandKey={PSEUDO_FOLDER_MY_URI}
                    folder={{
                      name: "My Publications",
                      icon: undefined,
                      iconImage: undefined,
                    }}
                    isActive={selectedFolderUri === PSEUDO_FOLDER_MY_URI}
                    expanded={expandedKeys.has(PSEUDO_FOLDER_MY_URI)}
                    onToggleExpanded={() => toggleExpanded(PSEUDO_FOLDER_MY_URI)}
                    publications={myPublications}
                    emptyLabel="No publications on your account discovered yet."
                    selectedPubId={selectedPubId}
                    onSelectPub={onSelectPub}
                    folders={folders}
                    prefsMap={prefsMap}
                  />
                ) : null}
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
                {showHiddenFolder ? (
                  <FolderBranch
                    expandKey={PSEUDO_FOLDER_HIDDEN_URI}
                    folder={{
                      name: "Hidden Publications",
                      icon: undefined,
                      iconImage: undefined,
                    }}
                    isActive={selectedFolderUri === PSEUDO_FOLDER_HIDDEN_URI}
                    expanded={expandedKeys.has(PSEUDO_FOLDER_HIDDEN_URI)}
                    onToggleExpanded={() => toggleExpanded(PSEUDO_FOLDER_HIDDEN_URI)}
                    publications={hiddenPubs}
                    emptyLabel="No hidden publications."
                    selectedPubId={selectedPubId}
                    onSelectPub={onSelectPub}
                    folders={folders}
                    prefsMap={prefsMap}
                  />
                ) : null}
                <NewFolderDialog />
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
        <div className="flex min-w-0 items-start gap-2 px-2 pb-2">
          <input
            id="show-hidden-folder"
            type="checkbox"
            checked={showHiddenFolder}
            onChange={(e) => setShowHiddenFolder(e.target.checked)}
            className="border-input text-primary focus-visible:ring-ring mt-0.5 size-4 shrink-0 rounded border shadow-xs focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:outline-none"
          />
          <Label
            htmlFor="show-hidden-folder"
            className="min-w-0 flex-1 cursor-pointer text-xs leading-snug font-normal text-sidebar-foreground"
          >
            Show Hidden Publications folder
          </Label>
        </div>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton
              type="button"
              tooltip="Log out"
              disabled={loggingOut}
              onClick={() => void handleLogout()}
            >
              <LogOut />
              <span>{loggingOut ? "Signing out…" : "Log out"}</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
      <SidebarResizeHandle />
    </Sidebar>
  );
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
