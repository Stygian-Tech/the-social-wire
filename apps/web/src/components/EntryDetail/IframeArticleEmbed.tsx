"use client";

import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { EmbedUnavailableMessage } from "@/components/EntryDetail/EmbedUnavailableMessage";
import { Skeleton } from "@/components/ui/skeleton";
import { articleFallbackContentIsVerified } from "@/lib/articleFallbackVerification";
import {
  getCachedEmbedProbeFrameable,
  setCachedEmbedProbeFrameable,
} from "@/lib/embedProbeCache";
import {
  isCachedUnstableEmbed,
  markUnstableEmbed,
  registerIframeLoadEvent,
} from "@/lib/embedIframeStability";
import { cn } from "@/lib/utils";

const EMBED_PROBE_DEBOUNCE_MS = 280;

export function IframeArticleEmbed({
  title,
  className,
  iframeSrc,
  fallbackContent,
  expectedAtUri,
  pageAtUri,
}: {
  title: string;
  className?: string;
  iframeSrc: string;
  fallbackContent?: ReactNode;
  expectedAtUri?: string;
  pageAtUri?: string;
}) {
  const cachedFrameable = getCachedEmbedProbeFrameable(iframeSrc);
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  const [unstableEmbed, setUnstableEmbed] = useState(() =>
    isCachedUnstableEmbed(iframeSrc),
  );
  const [probeBlocksEmbed, setProbeBlocksEmbed] = useState<boolean | null>(
    () => (cachedFrameable === undefined ? null : !cachedFrameable),
  );
  const loadTimestampsRef = useRef<number[]>([]);
  const probeGeneration = useRef(0);
  const handleLoad = useCallback(() => {
    const { timestamps, unstable } = registerIframeLoadEvent(
      loadTimestampsRef.current,
    );
    loadTimestampsRef.current = timestamps;
    if (unstable) {
      markUnstableEmbed(iframeSrc);
      setUnstableEmbed(true);
    }
    setLoaded(true);
    setFailed(false);
  }, [iframeSrc]);
  const handleError = useCallback(() => {
    setFailed(true);
    setLoaded(true);
  }, []);
  useEffect(() => {
    if (getCachedEmbedProbeFrameable(iframeSrc) !== undefined) return;
    const gen = ++probeGeneration.current;
    const ac = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const response = await fetch(
          `/api/embed-frame?url=${encodeURIComponent(iframeSrc)}`,
          { signal: ac.signal },
        );
        if (gen !== probeGeneration.current) return;
        if (!response.ok) {
          setCachedEmbedProbeFrameable(iframeSrc, true);
          setProbeBlocksEmbed(false);
          return;
        }
        const body = (await response.json()) as { frameable?: boolean };
        if (gen !== probeGeneration.current) return;
        const frameable = body.frameable !== false;
        setCachedEmbedProbeFrameable(iframeSrc, frameable);
        setProbeBlocksEmbed(!frameable);
      } catch {
        if (gen !== probeGeneration.current || ac.signal.aborted) return;
        setCachedEmbedProbeFrameable(iframeSrc, true);
        setProbeBlocksEmbed(false);
      }
    }, EMBED_PROBE_DEBOUNCE_MS);
    return () => {
      clearTimeout(timer);
      ac.abort();
    };
  }, [iframeSrc]);
  const showIframe = probeBlocksEmbed === false && !failed && !unstableEmbed;
  const showBusyOverlay =
    !loaded &&
    !failed &&
    !unstableEmbed &&
    (probeBlocksEmbed === null || showIframe);
  const verifiedFallbackContent = articleFallbackContentIsVerified({
    expectedAtUri,
    pageAtUri,
  })
    ? fallbackContent
    : undefined;
  return (
    <div
      className={cn(
        "relative flex min-h-0 w-full flex-1 flex-col overflow-hidden",
        className,
      )}
    >
      {showBusyOverlay ? (
        <div className="absolute inset-0 z-10 flex min-h-0 flex-col bg-background">
          <Skeleton className="min-h-0 h-full w-full rounded-none" />
        </div>
      ) : null}
      {probeBlocksEmbed === true ? (
        <EmbedUnavailableMessage
          href={iframeSrc}
          message="This site blocks embedding."
          linkLabel="Open"
          fallbackContent={verifiedFallbackContent}
        />
      ) : unstableEmbed ? (
        <EmbedUnavailableMessage
          href={iframeSrc}
          message="This page keeps reloading when embedded. Open it in a new tab to read."
          linkLabel="Open in New Tab"
          fallbackContent={verifiedFallbackContent}
        />
      ) : failed ? (
        <EmbedUnavailableMessage
          href={iframeSrc}
          message="This page cannot be embedded. Open it in a new tab or read the saved content below."
          linkLabel="Open in New Tab"
          fallbackContent={verifiedFallbackContent}
        />
      ) : showIframe ? (
        <iframe
          title={`Embedded article: ${title}`}
          src={iframeSrc}
          className={cn(
            "block h-full min-h-0 w-full bg-background",
            !loaded && "opacity-0",
          )}
          onLoad={handleLoad}
          onError={handleError}
          sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms"
          referrerPolicy="no-referrer-when-downgrade"
        />
      ) : null}
    </div>
  );
}
