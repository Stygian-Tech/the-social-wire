"use client";

import { useMemo } from "react";

import { EntryCardActionMenu } from "@/components/EntryList/EntryCardActionMenu";
import { EntryRowActions } from "@/components/EntryList/EntryRowActions";
import { CachedImage } from "@/components/shared/CachedImage";
import { PublicationChip } from "@/components/shared/PublicationChip";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import { Tooltip, TooltipTrigger } from "@/components/ui/tooltip";
import type { EntryListItem } from "@/lib/atprotoClient";
import { decodeHtmlEntities } from "@/lib/decodeHtmlEntities";
import { cn } from "@/lib/utils";
import { wireReasonLabel } from "@/lib/wireFeedClient";
import { WireStoryHoverMetadata } from "./WireStoryHoverMetadata";

export type WireStoryCardVariant =
  | "lead"
  | "supporting"
  | "standard"
  | "compact"
  | "trending";

export function WireStoryCard({
  story,
  variant = "standard",
  rank,
  onSelect,
}: {
  story: EntryListItem;
  variant?: WireStoryCardVariant;
  rank?: number;
  onSelect: (entryId: string, entry?: EntryListItem) => void;
}) {
  const source = story.wireItem?.source;
  const publicationName =
    source?.name.trim() ||
    source?.domain.trim() ||
    "Publication";
  const title = useMemo(() => decodeHtmlEntities(story.title), [story.title]);
  const summary = useMemo(
    () => (story.summary ? decodeHtmlEntities(story.summary) : undefined),
    [story.summary],
  );
  const date = new Date(story.publishedAt);
  const formattedDate = Number.isNaN(date.getTime())
    ? null
    : date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  const detailedDate = Number.isNaN(date.getTime())
    ? undefined
    : date.toLocaleString(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      });
  const reason = story.wireItem?.reasons
    .map(wireReasonLabel)
    .find((label): label is string => Boolean(label));
  const showImage = variant !== "compact";

  const card = (
    <div
      role="link"
      tabIndex={0}
      data-wire-story-id={story.wireItem?.itemId ?? story.entryId}
      onClick={() => onSelect(story.entryId, story)}
      onKeyDown={(event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        onSelect(story.entryId, story);
      }}
      className={cn(
        "group/story relative h-full cursor-pointer overflow-hidden rounded-2xl border border-border/70 bg-card/88 text-left shadow-[var(--soft-elevation)] outline-none transition-[border-color,background-color,box-shadow] hover:border-[var(--purple-border)] hover:bg-muted/30 hover:[box-shadow:var(--purple-glow-hover)] focus-visible:ring-2 focus-visible:ring-ring dark:border-border/55 dark:bg-card/82",
        variant === "supporting" &&
          "lg:grid lg:grid-cols-[minmax(0,1fr)_9rem]",
        variant === "compact" && "rounded-xl shadow-sm",
        variant === "trending" &&
          "grid grid-cols-[minmax(0,1fr)_4.75rem] rounded-xl shadow-sm",
      )}
    >
      {showImage ? (
        <div
          className={cn(
            "relative overflow-hidden bg-muted/45",
            variant === "lead"
              ? "aspect-[16/7.5]"
              : variant === "supporting"
                ? "aspect-[16/9] lg:col-start-2 lg:row-start-1 lg:my-1.5 lg:mr-1.5 lg:aspect-[4/3] lg:self-center lg:rounded-xl"
                : variant === "trending"
                  ? "col-start-2 row-start-1 m-1.5 min-h-[4.75rem] rounded-lg"
                : "aspect-[16/9]",
          )}
        >
          <CachedImage
            src={story.thumbnailUrl}
            alt=""
            width={variant === "lead" ? 960 : 480}
            height={variant === "lead" ? 450 : 270}
            loading={variant === "lead" ? "eager" : "lazy"}
            className="absolute inset-0 size-full object-cover transition-transform duration-300 group-hover/story:scale-[1.015]"
          />
          {rank && variant !== "trending" ? (
            <span className="absolute left-3 top-3 inline-flex size-8 items-center justify-center rounded-full bg-background/92 text-sm font-bold text-foreground shadow-sm backdrop-blur-sm">
              {rank}
            </span>
          ) : null}
        </div>
      ) : null}
      <div
        className={cn(
          "relative p-3.5",
          variant === "lead" && "p-4 sm:p-5",
          variant === "supporting" &&
            "lg:col-start-1 lg:row-start-1 lg:self-center lg:p-3",
          variant === "trending" && "col-start-1 row-start-1 p-2.5 pr-1",
        )}
      >
        <div
          className={cn(
            "mb-2 flex min-w-0 items-center gap-2 pr-8",
            variant === "supporting" && "lg:mb-1.5",
          )}
        >
          {(variant === "compact" || variant === "trending") && rank ? (
            <span className="inline-flex size-6 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-bold text-[var(--purple-foreground)]">
              {rank}
            </span>
          ) : null}
          <span
            className={cn(
              "min-w-0",
              variant === "supporting" && "lg:flex-1",
            )}
            onClick={
              source?.homepageUrl
                ? (event) => event.stopPropagation()
                : undefined
            }
            onKeyDown={
              source?.homepageUrl
                ? (event) => event.stopPropagation()
                : undefined
            }
          >
            <PublicationChip
              publication={{
                name: publicationName,
                faviconUrl: source?.iconUrl,
                homepageUrl: source?.homepageUrl,
              }}
              className={cn(
                "max-w-full border-0 bg-transparent px-0 py-0 text-foreground",
                variant === "lead" ? "text-sm" : "text-xs",
                variant === "supporting" && "lg:w-full lg:items-start",
              )}
              nameClassName={cn(
                variant === "supporting" &&
                  "lg:overflow-visible lg:text-clip lg:whitespace-normal lg:text-left lg:leading-tight",
              )}
            />
          </span>
          {formattedDate && variant !== "trending" ? (
            <span
              className={cn(
                "shrink-0 text-xs text-muted-foreground",
                variant === "supporting" && "lg:hidden",
              )}
            >
              {formattedDate}
            </span>
          ) : null}
        </div>
        <h3
          className={cn(
            "font-bold leading-tight text-foreground underline-offset-4 group-hover/story:underline",
            variant === "lead"
              ? "line-clamp-3 text-2xl sm:text-3xl"
              : variant === "compact"
                ? "line-clamp-2 text-sm"
                : variant === "trending"
                  ? "line-clamp-2 text-sm"
                : variant === "supporting"
                  ? "line-clamp-2 text-base"
                  : "line-clamp-2 text-lg",
          )}
        >
          {title}
        </h3>
        {variant !== "compact" &&
        variant !== "trending" &&
        variant !== "supporting" &&
        summary ? (
          <p
            className={cn(
              "mt-2 text-sm leading-5 text-muted-foreground",
              "line-clamp-2",
            )}
          >
            {summary}
          </p>
        ) : null}
        <div
          className={cn(
            "mt-2 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 pr-8 text-xs text-muted-foreground",
            variant === "supporting" && "lg:mt-1.5",
          )}
        >
          {reason ? (
            <span className="rounded-full bg-primary/10 px-2 py-0.5 font-semibold text-[var(--purple-foreground)]">
              {reason}
            </span>
          ) : null}
          {source?.author?.trim() ? (
            <span className="truncate">By {source.author}</span>
          ) : null}
          {variant === "trending" && formattedDate ? (
            <span className="shrink-0">{formattedDate}</span>
          ) : null}
          {variant === "trending" && source?.domain.trim() ? (
            <span className="basis-full truncate">{source.domain}</span>
          ) : null}
        </div>
        <div className="absolute bottom-2 right-2">
          <EntryCardActionMenu entry={story} />
        </div>
      </div>
    </div>
  );

  return (
    <ContextMenu>
      <Tooltip>
        <ContextMenuTrigger className="block h-full min-w-0">
          <TooltipTrigger delay={350} render={card} />
        </ContextMenuTrigger>
        <WireStoryHoverMetadata
          title={title}
          publicationName={publicationName}
          site={source?.domain.trim() || publicationName}
          author={source?.author?.trim() || undefined}
          publishedAt={detailedDate}
        />
      </Tooltip>
      <ContextMenuContent className="min-w-[11rem]">
        <EntryRowActions
          entry={story}
          isRead
          readIndicatorsEnabled={false}
          onMarkEntryRead={() => undefined}
          onMarkEntryUnread={() => undefined}
          variant="context"
        />
      </ContextMenuContent>
    </ContextMenu>
  );
}
