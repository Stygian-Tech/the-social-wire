"use client";

import { sanitizeOEmbedHtml } from "@/lib/sanitizeOEmbedHtml";
import type { OEmbedResponse } from "@/lib/oEmbed";

type Props = {
  oembed: OEmbedResponse;
  pageUrl: string;
};

export function OEmbedArticleView({ oembed, pageUrl }: Props) {
  if (oembed.type === "photo" && oembed.url) {
    return (
      <div className="flex h-full flex-col items-center overflow-auto bg-background p-6">
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
    return (
      <div
        className="h-full overflow-auto bg-background p-4 [&_iframe]:aspect-video [&_iframe]:h-auto [&_iframe]:max-w-full [&_iframe]:w-full"
        dangerouslySetInnerHTML={{ __html: html }}
      />
    );
  }

  if (oembed.type === "video" && oembed.url) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-3 bg-background p-6 text-center">
        <p className="text-sm text-muted-foreground">
          {oembed.title ?? "Video embed"}
        </p>
        <a
          href={oembed.url}
          target="_blank"
          rel="noopener noreferrer"
          className="text-sm font-medium text-primary underline-offset-4 hover:underline"
        >
          Open in New Tab
        </a>
      </div>
    );
  }

  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 bg-background p-6 text-center">
      <p className="text-sm text-muted-foreground">Could not render this embed.</p>
      <a
        href={pageUrl}
        target="_blank"
        rel="noopener noreferrer"
        className="text-sm font-medium text-primary underline-offset-4 hover:underline"
      >
        Open in New Tab
      </a>
    </div>
  );
}
