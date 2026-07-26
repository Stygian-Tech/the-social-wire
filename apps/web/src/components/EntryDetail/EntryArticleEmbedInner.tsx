"use client";

import { useEffect, useRef, useState } from "react";
import { IframeArticleEmbed } from "@/components/EntryDetail/IframeArticleEmbed";
import type { EntryArticleEmbedProps } from "@/components/EntryDetail/EntryArticleEmbedTypes";
import { OEmbedArticleView } from "@/components/EntryDetail/OEmbedArticleView";
import { Skeleton } from "@/components/ui/skeleton";
import { fetchOEmbedForPage } from "@/lib/oEmbedClient";
import { getCachedOEmbed } from "@/lib/oEmbedCache";
import { cn } from "@/lib/utils";

type OEmbedPhase = "pending" | "hit" | "miss";
export function EntryArticleEmbedInner({
  title,
  className,
  fallbackContent,
  expectedAtUri,
  pageUrl,
}: Omit<EntryArticleEmbedProps, "url"> & { pageUrl: string }) {
  const cachedOEmbed = getCachedOEmbed(pageUrl);
  const [oembedPhase, setOembedPhase] = useState<OEmbedPhase>(() =>
    !cachedOEmbed ? "pending" : cachedOEmbed.status === "hit" ? "hit" : "miss",
  );
  const [oembedPayload, setOembedPayload] = useState(() =>
    cachedOEmbed?.status === "hit" ? cachedOEmbed.oembed : null,
  );
  const [pageAtUri, setPageAtUri] = useState(cachedOEmbed?.pageAtUri);
  const oembedGeneration = useRef(0);
  useEffect(() => {
    if (cachedOEmbed) return;
    const gen = ++oembedGeneration.current;
    const ac = new AbortController();
    void (async () => {
      const result = await fetchOEmbedForPage(pageUrl, ac.signal);
      if (gen !== oembedGeneration.current || ac.signal.aborted) return;
      setPageAtUri(result.pageAtUri);
      if (result.ok) {
        setOembedPayload(result.oembed);
        setOembedPhase("hit");
      } else setOembedPhase("miss");
    })();
    return () => ac.abort();
  }, [pageUrl, cachedOEmbed]);
  if (oembedPhase === "pending")
    return (
      <div
        className={cn(
          "relative flex min-h-0 w-full flex-1 flex-col overflow-hidden",
          className,
        )}
      >
        <Skeleton className="min-h-0 h-full w-full rounded-none" />
      </div>
    );
  if (oembedPhase === "hit" && oembedPayload)
    return (
      <div
        className={cn(
          "relative flex min-h-0 w-full flex-1 flex-col overflow-hidden",
          className,
        )}
      >
        <OEmbedArticleView oembed={oembedPayload} pageUrl={pageUrl} />
      </div>
    );
  return (
    <IframeArticleEmbed
      title={title}
      className={className}
      iframeSrc={pageUrl}
      fallbackContent={fallbackContent}
      expectedAtUri={expectedAtUri}
      pageAtUri={pageAtUri}
    />
  );
}
