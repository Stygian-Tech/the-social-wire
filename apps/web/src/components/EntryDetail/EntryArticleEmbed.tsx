"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ExternalLink } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
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
        Open in new tab
      </a>
    </div>
  );
}

/** iframe embed of the canonical article URL with sandbox defaults and loading UI. */
export function EntryArticleEmbed({
  url,
  title,
  className,
}: EntryArticleEmbedProps) {
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  /** `null` = probe in progress; `true` = headers say framing is blocked. */
  const [probeBlocksEmbed, setProbeBlocksEmbed] = useState<boolean | null>(null);

  const iframeSrc = useMemo(() => sanitizeEmbedUrlForIframe(url), [url]);

  const handleLoad = useCallback(() => {
    setLoaded(true);
    setFailed(false);
  }, []);

  const handleError = useCallback(() => {
    setFailed(true);
    setLoaded(true);
  }, []);

  const probeGeneration = useRef(0);

  useEffect(() => {
    setProbeBlocksEmbed(null);
    setLoaded(false);
    setFailed(false);
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
          setProbeBlocksEmbed(false);
          return;
        }
        const body = (await r.json()) as { frameable?: boolean };
        if (gen !== probeGeneration.current) return;
        setProbeBlocksEmbed(body.frameable === false);
      } catch {
        if (gen !== probeGeneration.current || ac.signal.aborted) return;
        setProbeBlocksEmbed(false);
      }
    }, EMBED_PROBE_DEBOUNCE_MS);
    return () => {
      clearTimeout(t);
      ac.abort();
    };
  }, [iframeSrc]);

  const showIframe = probeBlocksEmbed === false && !failed;
  const showBusyOverlay =
    probeBlocksEmbed === null || (showIframe && !loaded && !failed);

  return (
    <div
      className={cn(
        "relative flex min-h-0 w-full flex-1 flex-col overflow-hidden rounded-lg",
        className
      )}
    >
      {showBusyOverlay && (
        <div className="absolute inset-0 z-10 flex min-h-0 flex-col gap-2 bg-background p-3 sm:p-4">
          <Skeleton className="min-h-0 h-full w-full rounded-md" />
        </div>
      )}
      {probeBlocksEmbed === true ? (
        <BlockedEmbedMessage href={iframeSrc} />
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
