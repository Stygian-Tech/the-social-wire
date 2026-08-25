import { TooltipContent } from "@/components/ui/tooltip";

export function WireStoryHoverMetadata({
  title,
  publicationName,
  site,
  author,
  publishedAt,
  rankingDiagnostics,
}: {
  title: string;
  publicationName: string;
  site: string;
  author?: string;
  publishedAt?: string;
  rankingDiagnostics?: {
    rank?: number;
    score?: number;
    scoreKind: "Ranking Score" | "Placement Score";
  };
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
        {rankingDiagnostics?.rank ? (
          <>
            <dt className="font-semibold opacity-70">Rank</dt>
            <dd className="tabular-nums">#{rankingDiagnostics.rank}</dd>
          </>
        ) : null}
        {Number.isFinite(rankingDiagnostics?.score) ? (
          <>
            <dt className="font-semibold opacity-70">
              {rankingDiagnostics?.scoreKind}
            </dt>
            <dd className="tabular-nums">
              {rankingDiagnostics?.score?.toFixed(4)} / 1.0000
            </dd>
          </>
        ) : null}
        {rankingDiagnostics ? (
          <>
            <dt className="font-semibold opacity-70">Weights</dt>
            <dd className="leading-4">
              Sharers 0.22× · Freshness 0.18× · Community 0.14× · Standard.site
              0.11× · Velocity 0.10× · Recommendations 0.10× · Source 0.08× ·
              Feedback 0.06× · Resurfacing 0.06× · Metadata 0.05× · Likes 0.02× ·
              Reposts 0.02× · Negative Feedback −0.10×
            </dd>
          </>
        ) : null}
      </dl>
    </TooltipContent>
  );
}
