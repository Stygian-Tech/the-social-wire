"use client";

import { Avatar } from "@/components/shared/Avatar";
import { Skeleton } from "@/components/ui/skeleton";
import {
  SidebarGroupLabel,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import { standardReaderListDisplayHandle } from "@/lib/standardReaderListDisplayHandle";
import { isDevDebugUiEnabled } from "@/lib/appEnv";
import type { StandardReaderList } from "@/lib/standardReaderListsClient";

export function SidebarListPublicationsSection({
  list,
  loading,
  error,
  selectedPubId,
  onSelectPub,
  onRetry,
}: {
  list?: StandardReaderList;
  loading: boolean;
  error?: string | null;
  selectedPubId: string | null;
  onSelectPub: (publicationId: string) => void;
  onRetry: () => void;
}) {
  const showDebugReferences = isDevDebugUiEnabled();
  const details = new Map(
    list?.publicationDetails?.map((publication) => [publication.publicationId, publication]),
  );

  return (
    <SidebarMenuItem>
      <SidebarGroupLabel className="lg:hidden">Publications</SidebarGroupLabel>
      {error ? (
        <div role="alert" className="px-2 py-2 text-xs text-muted-foreground">
          <p>{error}</p>
          <button type="button" onClick={onRetry} className="mt-1 text-primary underline">
            Retry
          </button>
        </div>
      ) : null}
      {loading && !list ? (
        <div role="status" aria-label="Loading List Publications" className="space-y-2 px-2 py-2">
          {[0, 1, 2].map((row) => <Skeleton key={row} className="h-7 w-full" />)}
        </div>
      ) : list?.publications.length === 0 ? (
        <p className="px-2 py-2 text-xs text-muted-foreground">No Publications In This List.</p>
      ) : list ? (
        <SidebarMenu aria-label="List Publications">
          {list.publications.map((publicationId) => {
            const publication = details.get(publicationId);
            const title = publication?.title || "Publication";
            const visibleId = !publicationId.startsWith("at://") || showDebugReferences ? publicationId : null;
            const handle = standardReaderListDisplayHandle(publication?.authorHandle);
            const reference = handle ? `@${handle}` : visibleId;
            return (
              <SidebarMenuItem key={publicationId}>
                <SidebarMenuButton
                  type="button"
                  isActive={selectedPubId === publicationId}
                  onClick={() => onSelectPub(publicationId)}
                  tooltip={reference ? `${title} — ${reference}` : title}
                  aria-label={publication || !visibleId ? title : `Publication: ${visibleId}`}
                  className="h-auto min-h-9 items-start py-2"
                >
                  <Avatar src={publication?.iconUrl ?? publication?.avatarUrl} alt="" size={20} className="size-5 shrink-0" />
                  <span className="flex min-w-0 flex-1 flex-col">
                    <span className="truncate">{title}</span>
                    {reference ? <span className="truncate text-xs font-normal text-muted-foreground">{reference}</span> : null}
                  </span>
                </SidebarMenuButton>
              </SidebarMenuItem>
            );
          })}
        </SidebarMenu>
      ) : null}
    </SidebarMenuItem>
  );
}
