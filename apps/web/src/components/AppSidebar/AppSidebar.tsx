"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { LogOut, RefreshCw } from "lucide-react";
import {
  Sidebar,
  SidebarContent,
  SidebarGroup,
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarHeader,
  SidebarFooter,
} from "@/components/ui/sidebar";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { FolderItem } from "./FolderItem";
import { PublicationItem } from "./PublicationItem";
import { NewFolderDialog } from "./NewFolderDialog";
import { useFolders } from "@/hooks/useFolders";
import {
  useDiscovery,
  usePublicationPrefs,
  useRefreshDiscovery,
} from "@/hooks/usePublications";
import { useAuth } from "@/hooks/useAuth";
import { rkeyFromURI } from "@/lib/pdsClient";

interface AppSidebarProps {
  selectedPubId: string | null;
  onSelectPub: (pubId: string) => void;
}

export function AppSidebar({ selectedPubId, onSelectPub }: AppSidebarProps) {
  const router = useRouter();
  const { session, signOut } = useAuth();
  const [loggingOut, setLoggingOut] = useState(false);
  const [selectedFolderUri, setSelectedFolderUri] = useState<string | null>(null);

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
  const refresh = useRefreshDiscovery();

  // Build a map: publicationId → prefs record
  const prefsMap = useMemo(
    () => new Map(prefs.map((p) => [p.value.publicationId, p])),
    [prefs]
  );

  // Filter visible (non-hidden) publications
  const visiblePubs = useMemo(
    () =>
      publications.filter((p) => {
        const pref = prefsMap.get(p.publicationId);
        return !pref?.value.hidden;
      }),
    [publications, prefsMap]
  );

  // Group publications: unfolderd go to "All Publications"
  const { folderMap, unfolderedPubs } = useMemo(() => {
    const folderMap = new Map<string, typeof visiblePubs>();
    const unfolderedPubs: typeof visiblePubs = [];

    for (const pub of visiblePubs) {
      const pref = prefsMap.get(pub.publicationId);
      const folderId = pref?.value.folderId;
      if (folderId) {
        const list = folderMap.get(folderId) ?? [];
        list.push(pub);
        folderMap.set(folderId, list);
      } else {
        unfolderedPubs.push(pub);
      }
    }

    return { folderMap, unfolderedPubs };
  }, [visiblePubs, prefsMap]);

  // Filter by selected folder (or show all)
  const displayedPubs = useMemo(() => {
    if (!selectedFolderUri) return unfolderedPubs;
    const rkey = rkeyFromURI(selectedFolderUri);
    return folderMap.get(rkey) ?? [];
  }, [selectedFolderUri, unfolderedPubs, folderMap]);

  return (
    <Sidebar>
      <SidebarHeader className="border-b px-4 py-3">
        <div className="flex items-center justify-between">
          <div className="flex flex-col gap-0.5">
            <span className="font-semibold text-sm">The Social Wire</span>
            <span className="inline-flex w-fit items-center rounded-full border px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground">
              Alpha
            </span>
          </div>
          <Button
            variant="ghost"
            size="icon"
            className="h-7 w-7"
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
        {/* Folders */}
        <SidebarGroup>
          <SidebarGroupLabel>Folders</SidebarGroupLabel>
          <SidebarMenu>
            {foldersLoading ? (
              <SidebarSkeleton count={3} />
            ) : (
              <>
                {/* "All Publications" pseudo-folder */}
                <FolderItem
                  folder={{
                    uri: "__all__",
                    cid: "",
                    value: {
                      $type: "com.thesocialwire.folder",
                      name: "All Publications",
                      createdAt: "",
                    },
                  }}
                  isSelected={selectedFolderUri === null}
                  onSelect={() => setSelectedFolderUri(null)}
                />
                {folders.map((f) => (
                  <FolderItem
                    key={f.uri}
                    folder={f}
                    isSelected={selectedFolderUri === f.uri}
                    onSelect={setSelectedFolderUri}
                  />
                ))}
                <NewFolderDialog />
              </>
            )}
          </SidebarMenu>
        </SidebarGroup>

        {/* Publications */}
        <SidebarGroup>
          <SidebarGroupLabel>Publications</SidebarGroupLabel>
          <SidebarMenu>
            {pubsLoading ? (
              <SidebarSkeleton count={5} />
            ) : displayedPubs.length === 0 ? (
              <p className="px-2 py-1 text-xs text-muted-foreground">
                {selectedFolderUri
                  ? "No publications in this folder."
                  : "No publications found. Try refreshing."}
              </p>
            ) : (
              displayedPubs.map((pub) => (
                <PublicationItem
                  key={pub.publicationId}
                  publication={pub}
                  isSelected={selectedPubId === pub.publicationId}
                  onSelect={onSelectPub}
                />
              ))
            )}
          </SidebarMenu>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter className="border-t px-2 py-3">
        <p className="px-2 text-xs text-muted-foreground truncate">
          {session?.did ?? ""}
        </p>
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
    </Sidebar>
  );
}

function SidebarSkeleton({ count }: { count: number }) {
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <Skeleton key={i} className="h-8 w-full rounded-md" />
      ))}
    </>
  );
}
