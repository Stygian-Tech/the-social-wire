"use client";

import { oEmbedHtmlLayout } from "@/lib/oEmbed";
import { outboundLinkProps } from "@/lib/outboundLinks";
import { sanitizeOEmbedHtml } from "@/lib/sanitizeOEmbedHtml";
import type { OEmbedResponse } from "@/lib/oEmbed";
import { cn } from "@/lib/utils";

type Props = {
  oembed: OEmbedResponse;
  pageUrl: string;
};

export function OEmbedArticleView({ oembed, pageUrl }: Props) {
  if (oembed.type === "photo" && oembed.url) {
    return (
      <div className="flex h-full min-h-0 flex-col items-center overflow-auto bg-background p-6">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={oembed.url}
          alt={oembed.title ?? "Embedded photo"}
          className="max-h-full max-w-full object-contain"
          width={oembed.width}
          height={oembed.height}
        />
        {oembed.title ? (
          <p className="mt-4 text-center text-sm text-muted-foreground">{oembed.title}</p>
        ) : null}
      </div>
    );
  }

  if ((oembed.type === "video" || oembed.type === "rich") && oembed.html) {
    const html = sanitizeOEmbedHtml(oembed.html);
    if (!html.trim()) {
      return null;
    }

    const layout =
      oembed.type === "video" ? "video" : oEmbedHtmlLayout(oembed.html);

    if (layout === "video") {
      return (
        <div className="flex h-full min-h-0 w-full items-center justify-center overflow-auto bg-background p-4">
          <div
            className="w-full max-w-4xl [&_iframe]:aspect-video [&_iframe]:h-auto [&_iframe]:w-full"
            dangerouslySetInnerHTML={{ __html: html }}
          />
        </div>
      );
    }

    return (
      <div className="relative h-full min-h-0 w-full flex-1 overflow-hidden bg-background">
        <div
          className={cn(
            "absolute inset-0",
            "[&_blockquote]:hidden",
            "[&_iframe]:block [&_iframe]:size-full [&_iframe]:min-h-0 [&_iframe]:border-0"
          )}
          dangerouslySetInnerHTML={{ __html: html }}
        />
      </div>
    );
  }

  if (oembed.type === "video" && oembed.url) {
    return (
      <div className="flex h-full min-h-0 flex-col items-center justify-center gap-3 bg-background p-6 text-center">
        <p className="text-sm text-muted-foreground">
          {oembed.title ?? "Video embed"}
        </p>
        <a
          href={oembed.url}
          {...outboundLinkProps}
          data-hypertext="true"
          className="text-sm font-medium"
        >
          Open in New Tab
        </a>
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col items-center justify-center gap-3 bg-background p-6 text-center">
      <p className="text-sm text-muted-foreground">Could not render this embed.</p>
      <a
        href={pageUrl}
        {...outboundLinkProps}
        data-hypertext="true"
        className="text-sm font-medium"
      >
        Open in New Tab
      </a>
    </div>
  );
}
