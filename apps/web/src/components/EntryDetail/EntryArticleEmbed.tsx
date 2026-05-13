"use client";

import { useCallback, useState } from "react";
import { ExternalLink } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";

interface EntryArticleEmbedProps {
  url: string;
  title: string;
  className?: string;
}

/** iframe embed of the canonical article URL with sandbox defaults and loading UI. */
export function EntryArticleEmbed({
  url,
  title,
  className,
}: EntryArticleEmbedProps) {
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);

  const handleLoad = useCallback(() => {
    setLoaded(true);
    setFailed(false);
  }, []);

  const handleError = useCallback(() => {
    setFailed(true);
    setLoaded(true);
  }, []);

  return (
    <div className={cn("flex flex-col gap-2", className)}>
      <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
        <div className="flex min-w-0 items-center gap-2">
          <span className="shrink-0 font-medium text-foreground">Live site</span>
          <a
            href={url}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex min-w-0 items-center gap-1 truncate hover:text-foreground hover:underline"
            title={url}
          >
            <ExternalLink className="size-3.5 shrink-0" />
            <span className="truncate">{url}</span>
          </a>
        </div>
        <a
          href={url}
          target="_blank"
          rel="noopener noreferrer"
          className={buttonVariants({ variant: "outline", size: "xs" })}
        >
          Open in new tab
        </a>
      </div>

      <div className="relative overflow-hidden rounded-lg border bg-background">
        {!loaded && !failed && (
          <div className="absolute inset-0 z-10 flex flex-col gap-2 p-4">
            <Skeleton className="h-4 w-1/3" />
            <Skeleton className="h-[min(70vh,560px)] w-full rounded-md" />
          </div>
        )}
        {failed ? (
          <div className="flex min-h-[200px] items-center justify-center p-6 text-center text-sm text-muted-foreground">
            This page cannot be embedded (the site may block iframes). Use
            &quot;Open in new tab&quot; or read the syndicated HTML below.
          </div>
        ) : (
          <iframe
            title={`Embedded article: ${title}`}
            src={url}
            className={cn(
              "block h-[min(78vh,720px)] w-full bg-background",
              !loaded && "opacity-0"
            )}
            onLoad={handleLoad}
            onError={handleError}
            sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-forms"
            referrerPolicy="no-referrer-when-downgrade"
          />
        )}
      </div>
    </div>
  );
}
