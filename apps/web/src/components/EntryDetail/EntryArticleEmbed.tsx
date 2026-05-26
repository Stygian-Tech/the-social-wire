"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ExternalLink } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import {
  getCachedEmbedProbeFrameable,
  setCachedEmbedProbeFrameable,
} from "@/lib/embedProbeCache";
import {
  isCachedUnstableEmbed,
  markUnstableEmbed,
  registerIframeLoadEvent,
} from "@/lib/embedIframeStability";
import { sanitizeEmbedUrlForIframe } from "@/lib/publicResourceUrl";
import { cn } from "@/lib/utils";

const EMBED_PROBE_DEBOUNCE_MS = 280;

interface EntryArticleEmbedProps {
  url: string;
  title: string;
  className?: string;
}

function BlockedEmbedMessage({ href }: { href: string }) {
  return (
    <div className="flex min-h-[200px] flex-col items-center justify-center gap-3 px-4 py-6 text-center text-sm text-muted-foreground">
      <p>This site blocks embedding.</p>
      <a
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        className="inline-flex min-h-[44px] items-center gap-1.5 rounded-md px-3 py-2 text-sm font-medium text-primary hover:underline"
      >
        <ExternalLink className="size-4 shrink-0" aria-hidden />
        Open
      </a>
    </div>
  );
}

function UnstableEmbedMessage({ href }: { href: string }) {
  return (
    <div className="flex min-h-[200px] flex-col items-center justify-center gap-3 px-4 py-6 text-center text-sm text-muted-foreground">
      <p>
        This page keeps reloading when embedded (common with some React sites). Open it in a new
        tab to read.
      </p>
      <a
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        className="inline-flex min-h-[44px] items-center gap-1.5 rounded-md px-3 py-2 text-sm font-medium text-primary hover:underline"
      >
        <ExternalLink className="size-4 shrink-0" aria-hidden />
        Open in New Tab
      </a>
    </div>
  );
}

function IframeLoadFailedMessage({ href }: { href: string }) {
  return (
    <div className="flex min-h-[200px] flex-col items-center justify-center gap-3 px-4 py-6 text-center text-sm text-muted-foreground">
      <p>
        This page cannot be embedded (the site may block iframes). Open it in a new tab or read the
        full content below.
      </p>
      <a
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        className="inline-flex min-h-[44px] items-center gap-1.5 rounded-md px-3 py-2 text-sm font-medium text-primary hover:underline"
      >
        <ExternalLink className="size-4 shrink-0" aria-hidden />
        Open in New Tab
      </a>
    </div>
  );
}

/** iframe embed of the canonical article URL with sandbox defaults and loading UI. */
export function EntryArticleEmbed(props: EntryArticleEmbedProps) {
  const iframeSrc = useMemo(
    () => sanitizeEmbedUrlForIframe(props.url),
    [props.url]
  );
  return <EntryArticleEmbedInner key={iframeSrc} {...props} iframeSrc={iframeSrc} />;
}

function EntryArticleEmbedInner({
  title,
  className,
  iframeSrc,
}: Omit<EntryArticleEmbedProps, "url"> & { iframeSrc: string }) {
  const cachedFrameable = getCachedEmbedProbeFrameable(iframeSrc);
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  const [unstableEmbed, setUnstableEmbed] = useState(() =>
    isCachedUnstableEmbed(iframeSrc)
  );
  /** `null` = probe in progress; `true` = headers say framing is blocked. */
  const [probeBlocksEmbed, setProbeBlocksEmbed] = useState<boolean | null>(() =>
    cachedFrameable === undefined ? null : !cachedFrameable
  );

  const loadTimestampsRef = useRef<number[]>([]);

  const handleLoad = useCallback(() => {
    const { timestamps, unstable } = registerIframeLoadEvent(
      loadTimestampsRef.current
    );
    loadTimestampsRef.current = timestamps;
    if (unstable) {
      markUnstableEmbed(iframeSrc);
      setUnstableEmbed(true);
      setLoaded(true);
      setFailed(false);
      return;
    }
    setLoaded(true);
    setFailed(false);
  }, [iframeSrc]);

  const handleError = useCallback(() => {
    setFailed(true);
    setLoaded(true);
  }, []);

  const probeGeneration = useRef(0);

  useEffect(() => {
    if (getCachedEmbedProbeFrameable(iframeSrc) !== undefined) {
      return;
    }

    const gen = ++probeGeneration.current;
    const ac = new AbortController();
    const t = setTimeout(async () => {
      try {
        const r = await fetch(
          `/api/embed-frame?url=${encodeURIComponent(iframeSrc)}`,
          { signal: ac.signal }
        );
        if (gen !== probeGeneration.current) return;
        if (!r.ok) {
          setCachedEmbedProbeFrameable(iframeSrc, true);
          setProbeBlocksEmbed(false);
          return;
        }
        const body = (await r.json()) as { frameable?: boolean };
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
      clearTimeout(t);
      ac.abort();
    };
  }, [iframeSrc]);

  const showIframe = probeBlocksEmbed === false && !failed && !unstableEmbed;
  const showBusyOverlay =
    !loaded &&
    !failed &&
    !unstableEmbed &&
    (probeBlocksEmbed === null || showIframe);

  return (
    <div
      className={cn(
        "relative flex min-h-0 w-full flex-1 flex-col overflow-hidden",
        className
      )}
    >
      {showBusyOverlay ? (
        <div className="absolute inset-0 z-10 flex min-h-0 flex-col bg-background">
          <Skeleton className="min-h-0 h-full w-full rounded-none" />
        </div>
      ) : null}
      {probeBlocksEmbed === true ? (
        <BlockedEmbedMessage href={iframeSrc} />
      ) : unstableEmbed ? (
        <UnstableEmbedMessage href={iframeSrc} />
      ) : failed ? (
        <IframeLoadFailedMessage href={iframeSrc} />
      ) : showIframe ? (
        <iframe
          title={`Embedded article: ${title}`}
          src={iframeSrc}
          className={cn(
            "block h-full min-h-0 w-full bg-background",
            !loaded && "opacity-0"
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
