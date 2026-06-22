"use client";

import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ExternalLink } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { OEmbedArticleView } from "@/components/EntryDetail/OEmbedArticleView";
import {
  getCachedEmbedProbeFrameable,
  setCachedEmbedProbeFrameable,
} from "@/lib/embedProbeCache";
import {
  isCachedUnstableEmbed,
  markUnstableEmbed,
  registerIframeLoadEvent,
} from "@/lib/embedIframeStability";
import { fetchOEmbedForPage } from "@/lib/oEmbedClient";
import { getCachedOEmbed } from "@/lib/oEmbedCache";
import { sanitizeEmbedUrlForIframe } from "@/lib/publicResourceUrl";
import { cn } from "@/lib/utils";

const EMBED_PROBE_DEBOUNCE_MS = 280;

interface EntryArticleEmbedProps {
  url: string;
  title: string;
  className?: string;
  fallbackContent?: ReactNode;
}

function EmbedUnavailableMessage({
  href,
  message,
  linkLabel,
  fallbackContent,
}: {
  href: string;
  message: string;
  linkLabel: string;
  fallbackContent?: ReactNode;
}) {
  if (fallbackContent) {
    return (
      <div className="min-h-0 flex-1 overflow-y-auto px-4 py-5">
        <div className="mb-5 rounded-xl border border-border bg-muted/35 p-4 text-sm text-muted-foreground">
          <p>{message}</p>
          <a
            href={href}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-3 inline-flex min-h-[44px] items-center gap-1.5 rounded-md py-2 text-sm font-medium text-primary hover:underline"
          >
            <ExternalLink className="size-4 shrink-0" aria-hidden />
            {linkLabel}
          </a>
        </div>
        {fallbackContent}
      </div>
    );
  }

  return (
    <div className="flex min-h-[200px] flex-col items-center justify-center gap-3 px-4 py-6 text-center text-sm text-muted-foreground">
      <p>{message}</p>
      <a
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        className="inline-flex min-h-[44px] items-center gap-1.5 rounded-md px-3 py-2 text-sm font-medium text-primary hover:underline"
      >
        <ExternalLink className="size-4 shrink-0" aria-hidden />
        {linkLabel}
      </a>
    </div>
  );
}

/** Article embed: oEmbed first, then sandboxed iframe with load-storm protection. */
export function EntryArticleEmbed(props: EntryArticleEmbedProps) {
  const pageUrl = useMemo(() => sanitizeEmbedUrlForIframe(props.url), [props.url]);
  return <EntryArticleEmbedInner key={pageUrl} {...props} pageUrl={pageUrl} />;
}

type OEmbedPhase = "pending" | "hit" | "miss";

function EntryArticleEmbedInner({
  title,
  className,
  fallbackContent,
  pageUrl,
}: Omit<EntryArticleEmbedProps, "url"> & { pageUrl: string }) {
  const cachedOEmbed = getCachedOEmbed(pageUrl);
  const [oembedPhase, setOembedPhase] = useState<OEmbedPhase>(() => {
    if (!cachedOEmbed) return "pending";
    return cachedOEmbed.status === "hit" ? "hit" : "miss";
  });
  const [oembedPayload, setOembedPayload] = useState(
    () => (cachedOEmbed?.status === "hit" ? cachedOEmbed.oembed : null)
  );

  const oembedGeneration = useRef(0);

  useEffect(() => {
    if (cachedOEmbed) return;

    const gen = ++oembedGeneration.current;
    const ac = new AbortController();

    void (async () => {
      const result = await fetchOEmbedForPage(pageUrl, ac.signal);
      if (gen !== oembedGeneration.current || ac.signal.aborted) return;
      if (result.ok) {
        setOembedPayload(result.oembed);
        setOembedPhase("hit");
      } else {
        setOembedPhase("miss");
      }
    })();

    return () => {
      ac.abort();
    };
  }, [pageUrl, cachedOEmbed]);

  if (oembedPhase === "pending") {
    return (
      <div
        className={cn(
          "relative flex min-h-0 w-full flex-1 flex-col overflow-hidden",
          className
        )}
      >
        <Skeleton className="min-h-0 h-full w-full rounded-none" />
      </div>
    );
  }

  if (oembedPhase === "hit" && oembedPayload) {
    return (
      <div
        className={cn(
          "relative flex min-h-0 w-full flex-1 flex-col overflow-hidden",
          className
        )}
      >
        <OEmbedArticleView oembed={oembedPayload} pageUrl={pageUrl} />
      </div>
    );
  }

  return (
    <IframeArticleEmbed
      title={title}
      className={className}
      iframeSrc={pageUrl}
      fallbackContent={fallbackContent}
    />
  );
}

function IframeArticleEmbed({
  title,
  className,
  iframeSrc,
  fallbackContent,
}: {
  title: string;
  className?: string;
  iframeSrc: string;
  fallbackContent?: ReactNode;
}) {
  const cachedFrameable = getCachedEmbedProbeFrameable(iframeSrc);
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  const [unstableEmbed, setUnstableEmbed] = useState(() =>
    isCachedUnstableEmbed(iframeSrc)
  );
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
        <EmbedUnavailableMessage
          href={iframeSrc}
          message="This site blocks embedding."
          linkLabel="Open"
          fallbackContent={fallbackContent}
        />
      ) : unstableEmbed ? (
        <EmbedUnavailableMessage
          href={iframeSrc}
          message="This page keeps reloading when embedded. Open it in a new tab to read."
          linkLabel="Open in New Tab"
          fallbackContent={fallbackContent}
        />
      ) : failed ? (
        <EmbedUnavailableMessage
          href={iframeSrc}
          message="This page cannot be embedded. Open it in a new tab or read the saved content below."
          linkLabel="Open in New Tab"
          fallbackContent={fallbackContent}
        />
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
