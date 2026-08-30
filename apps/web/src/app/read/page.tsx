"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { Suspense } from "react";
import { useEffect, useState } from "react";
import ReadPubPage from "./[...pubId]/ReadPubPage";
import { useWireFeedCatalog } from "@/hooks/useWireFeed";
import { useCircleCatalog } from "@/hooks/useCircleFeed";
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
  const folder = params.get("folder");
  const feed = params.get("feed");
  const catalog = useWireFeedCatalog();
  const circleCatalog = useCircleCatalog();
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
    if (!selectionState.loaded || folder || feed || !rememberedFeed) return;
    router.replace(`/read?feed=${rememberedFeed}`);
  }, [feed, folder, rememberedFeed, router, selectionState.loaded]);

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
  const circleAvailable =
    circleCatalog.data?.enabled === true &&
    circleCatalog.data.available === true;
  if (feed === "circle") {
    if (circleAvailable) return <ReadPubPage key="circle" circleFeed />;
    return (
      <div className="flex h-full flex-1 items-center justify-center p-8 text-sm text-muted-foreground">
        {circleCatalog.isLoading
          ? "Loading Your Circle…"
          : "Your Circle is unavailable."}
      </div>
    );
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
