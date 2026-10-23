/* eslint-disable @next/next/no-img-element -- Preserve publisher image formats. */
import type { ReactNode } from "react";
import { BookOpen, Newspaper } from "lucide-react";
import type { StandardSiteEmbed } from "@/lib/standardSiteEmbedClient";
import { socialHttpsUrl } from "./socialUrls";

export function StandardSiteArticleCard({ metadata, thumb, children }: { metadata: StandardSiteEmbed; thumb?: string; children?: ReactNode }) {
  const image = socialHttpsUrl(thumb);
  const linkStyle = "inline-flex min-h-11 items-center gap-2 rounded-md px-3 py-2 text-sm font-medium hover:bg-muted focus-visible:outline-2 focus-visible:outline-ring";
  return <section aria-label="Article Preview" className="overflow-hidden rounded-xl border bg-muted/30" onClick={event => event.stopPropagation()}>
    <a href={metadata.articleUrl} target="_blank" rel="noopener noreferrer" className="block hover:bg-muted/60">
      {image ? <img src={image} alt="" loading="lazy" referrerPolicy="no-referrer" className="mx-auto block h-auto max-h-60 w-auto max-w-full" /> : null}
      <div className="space-y-2 p-3">
        <p className="text-sm font-semibold">{metadata.title}</p>
        {metadata.description ? <p className="line-clamp-3 text-sm text-muted-foreground">{metadata.description}</p> : null}
      </div>
    </a>
    <a href={metadata.publicationUrl} target="_blank" rel="noopener noreferrer" className="flex items-center gap-2 px-3 pb-3 text-sm font-medium hover:underline">
      <Newspaper className="size-4 shrink-0" aria-hidden="true" />{metadata.publicationName}
    </a>
    <div className="flex flex-wrap items-center gap-1 border-t p-1">
      <a className={linkStyle} href={metadata.articleUrl} target="_blank" rel="noopener noreferrer"><BookOpen className="size-4" aria-hidden="true" />Read Article</a>
      <a className={linkStyle} href={metadata.publicationUrl} target="_blank" rel="noopener noreferrer">View Publication</a>
      {children}
    </div>
  </section>;
}
