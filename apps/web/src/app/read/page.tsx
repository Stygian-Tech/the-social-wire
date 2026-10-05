"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { Suspense } from "react";
import dynamic from "next/dynamic";
const SportsExperience = dynamic(() => import("@/components/SportsExperience"));
const FinanceExperience = dynamic(() => import("@/components/FinanceExperience"));
import { useEffect, useState } from "react";
import { navigateTopicFeed } from "@/lib/topicFeedNavigation";
import ReadPubPage from "./[...pubId]/ReadPubPage";
import { useWireFeedCatalog } from "@/hooks/useWireFeed";
import {
  isReaderFeedSelection,
  loadReaderFeedSelection,
  type ReaderFeedSelection,
} from "@/lib/readerFeedSelectionStorage";

export default function ReadIndexPage() {
  return (
    <Suspense fallback={null}>
      <ReadIndexContent />
    </Suspense>
  );
}

function ReadIndexContent() {
  const params = useSearchParams();
  const router = useRouter();
  const list = params.get("list");
  const folder = params.get("folder");
  const feed = params.get("feed");
  const catalog = useWireFeedCatalog();
  const [selectionState, setSelectionState] = useState<{
    loaded: boolean;
    feed: ReaderFeedSelection | null;
  }>({ loaded: false, feed: null });

  useEffect(() => {
    queueMicrotask(() =>
      setSelectionState({
        loaded: true,
        feed: loadReaderFeedSelection(window.localStorage),
      }),
    );
  }, []);
  const rememberedFeed = selectionState.feed;

  useEffect(() => {
    if (!selectionState.loaded || list || folder || feed || !rememberedFeed) return;
    router.replace(`/read?feed=${rememberedFeed}`);
  }, [feed, list, folder, rememberedFeed, router, selectionState.loaded]);

  if (list) return <ReadPubPage key={`list:${list}`} aggregateFeed={{kind:"list",id:list}} />;
  if (folder) {
    return (
      <ReadPubPage
        key={`folder:${folder}`}
        aggregateFeed={{ kind: "folder", id: folder }}
      />
    );
  }
  const wireAvailable =
    catalog.data?.enabled === true && catalog.data.available === true;
  if (feed === "wire") {
    if (wireAvailable) return <ReadPubPage key="wire" wireFeed />;
    return (
      <div className="flex h-full flex-1 items-center justify-center p-8 text-sm text-muted-foreground">
        {catalog.isLoading ? "Loading The Wire…" : "The Wire is unavailable."}
      </div>
    );
  }
  if (feed === "sports") return <SportsExperience key="sports" feedID={params.get("sportsFeed") || "sports"} onFeedChange={id => navigateTopicFeed("sports", id, params)} />;
  if (feed === "finance") return <FinanceExperience key="finance" feedID={params.get("financeFeed") || "finance"} onFeedChange={id => navigateTopicFeed("finance", id, params)} />;
  if (feed === "circle") {
    return <ReadPubPage key="circle" circleFeed />;
  }
  if (feed && !isReaderFeedSelection(feed)) {
    return (
      <div className="flex h-full flex-1 items-center justify-center p-8 text-sm text-muted-foreground">
        This feed is unavailable.
      </div>
    );
  }
  if (!feed && (!selectionState.loaded || rememberedFeed)) {
    return null;
  }
  const kind =
    feed === "following" || (!feed && rememberedFeed === "following")
      ? "following"
      : "subscribed";
  return (
    <ReadPubPage
      key={kind}
      aggregateFeed={{ kind }}
    />
  );
}
