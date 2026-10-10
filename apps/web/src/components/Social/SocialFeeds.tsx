"use client";

import { List, Rss, Users } from "lucide-react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useBlueskySocialCatalog } from "@/hooks/useBlueskySocialCatalog";
import { SOCIAL_FOLLOWING_FEED, socialFeedHref } from "@/lib/blueskySocialClient";
import { floatingSidebarRowClassName } from "@/components/shared/floatingSidebarStyles";
import { Skeleton } from "@/components/ui/skeleton";

export function SocialFeeds({ onSelect }: { onSelect?: () => void }) {
  const params = useSearchParams();
  const pathname = usePathname();
  const router = useRouter();
  const catalog = useBlueskySocialCatalog();
  const feeds = catalog.isError ? [SOCIAL_FOLLOWING_FEED] : catalog.data?.feeds ?? [SOCIAL_FOLLOWING_FEED];
  const selectedFeed = params.get("feed");
  const selectedList = params.get("list");

  return <nav aria-label="Social Feeds" className="flex min-w-0 flex-col gap-1">
    {feeds.map(feed => {
      const selected = pathname === "/social" && (feed.kind === "following" ? !selectedFeed && !selectedList
        : feed.kind === "feed" ? selectedFeed === feed.uri && !selectedList
          : selectedList === feed.uri && !selectedFeed);
      const Icon = feed.kind === "following" ? Users : feed.kind === "list" ? List : Rss;
      return <button
        key={`${feed.kind}:${feed.uri}`}
        type="button"
        aria-current={selected ? "page" : undefined}
        className={`${floatingSidebarRowClassName} w-full text-left hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring aria-[current=page]:bg-accent aria-[current=page]:text-accent-foreground`}
        onClick={() => { router.push(socialFeedHref(feed)); onSelect?.(); }}
      >
        <Icon aria-hidden="true" className="size-4 shrink-0" />
        <span className="min-w-0 break-words [overflow-wrap:anywhere]">{feed.name}</span>
      </button>;
    })}
    {catalog.isPending ? <div role="status" aria-label="Loading Social Feeds" className="flex items-center gap-2 p-2">
      <Skeleton className="size-4" /><Skeleton className="h-4 w-28" />
    </div> : null}
    {catalog.isError ? <div className="px-2 py-1 text-xs text-muted-foreground">
      <p role="status">Couldn’t load saved feeds.</p>
      <button type="button" className="mt-2 rounded px-2 py-1 text-sm hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring" onClick={() => { void catalog.refetch(); }}>Retry</button>
    </div> : null}
  </nav>;
}
