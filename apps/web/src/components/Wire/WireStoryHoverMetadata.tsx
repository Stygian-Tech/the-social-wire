import { TooltipContent } from "@/components/ui/tooltip";

export function WireStoryHoverMetadata({
  title,
  publicationName,
  site,
  author,
  publishedAt,
}: {
  title: string;
  publicationName: string;
  site: string;
  author?: string;
  publishedAt?: string;
}) {
  return (
    <TooltipContent
      data-wire-story-hover-metadata
      side="top"
      align="start"
      sideOffset={8}
      arrowClassName="bg-popover fill-popover"
      className="w-[min(22rem,calc(100vw-2rem))] max-w-none flex-col items-start gap-2 border border-border bg-popover px-3 py-2.5 text-left text-popover-foreground shadow-lg"
    >
      <p className="text-sm font-semibold leading-snug">{title}</p>
      <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2 gap-y-1 text-[11px] leading-4">
        <dt className="font-semibold opacity-70">Publication</dt>
        <dd>{publicationName}</dd>
        <dt className="font-semibold opacity-70">Site</dt>
        <dd className="break-all">{site}</dd>
        {author ? (
          <>
            <dt className="font-semibold opacity-70">Author</dt>
            <dd>{author}</dd>
          </>
        ) : null}
        {publishedAt ? (
          <>
            <dt className="font-semibold opacity-70">Published</dt>
            <dd>{publishedAt}</dd>
          </>
        ) : null}
      </dl>
    </TooltipContent>
  );
}
