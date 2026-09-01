"use client";

import { useMemo, useState } from "react";
import { EyeOff } from "lucide-react";

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
import { isDevDebugUiEnabled } from "@/lib/appEnv";
import { decodeHtmlEntities } from "@/lib/decodeHtmlEntities";
import { thumbnailImageSrcAttempts } from "@/lib/publicResourceUrl";
import { cn } from "@/lib/utils";
import { wireReasonLabel } from "@/lib/wireFeedClient";
import { WireStoryHoverMetadata } from "./WireStoryHoverMetadata";
import { CircleSharerStrip } from "@/components/Circle/CircleSharerStrip";
import { useCircleStoryActions } from "@/components/Circle/CircleStoryActionsContext";
import { circleReasonLabel } from "@/lib/circleFeedClient";

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
  const circleItem = story.circleItem;
  const circleActions = useCircleStoryActions();
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
  const reason = (
    circleItem?.reasons.map(circleReasonLabel) ??
    story.wireItem?.reasons.map(wireReasonLabel) ??
    []
  ).find((label): label is string => Boolean(label));
  const showImage = variant !== "compact";
  const thumbnailAttempts = useMemo(
    () =>
      thumbnailImageSrcAttempts(
        story.thumbnailUrl,
        story.thumbnailFallbackUrl,
      ),
    [story.thumbnailFallbackUrl, story.thumbnailUrl],
  );
  const [failedThumbnailUrls, setFailedThumbnailUrls] = useState<Set<string>>(
    () => new Set(),
  );
  const thumbnailUrl = thumbnailAttempts.find(
    (attempt) => !failedThumbnailUrls.has(attempt),
  );
  const rendersThumbnail = showImage && Boolean(thumbnailUrl);

  if (circleItem && circleActions?.isHidden(circleItem.storyId)) {
    return (
      <div className="flex min-h-24 items-center justify-between gap-3 rounded-2xl border border-dashed border-border bg-muted/20 px-4 py-3 text-sm text-muted-foreground">
        <span>Story hidden from Your Circle.</span>
        <button
          type="button"
          disabled={circleActions.isPending(circleItem.storyId)}
          className="font-semibold text-primary underline-offset-4 hover:underline disabled:opacity-50"
          onClick={() => circleActions.undo(circleItem.storyId)}
        >
          Undo
        </button>
      </div>
    );
  }

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
        variant === "supporting" && rendersThumbnail &&
          "lg:grid lg:grid-cols-[minmax(0,1fr)_9rem]",
        variant === "compact" && "rounded-xl shadow-sm",
        variant === "trending" &&
          "rounded-none border-0 bg-transparent shadow-none hover:border-transparent hover:bg-muted/35 hover:shadow-none dark:bg-transparent",
        variant === "trending" && rendersThumbnail &&
          "grid grid-cols-[minmax(0,1fr)_7rem]",
      )}
    >
      {rendersThumbnail ? (
        <div
          data-wire-story-media
          className={cn(
            "relative overflow-hidden bg-muted/45",
            variant === "lead"
              ? "aspect-[16/7.5]"
              : variant === "supporting"
                ? "aspect-[16/9] lg:col-start-2 lg:row-start-1 lg:my-1.5 lg:mr-1.5 lg:aspect-[4/3] lg:self-center lg:rounded-xl"
                : variant === "trending"
                  ? "col-start-2 row-start-1 m-1.5 aspect-[4/3] self-center rounded-lg"
                : "aspect-[16/9]",
          )}
        >
          <CachedImage
            src={thumbnailUrl}
            alt=""
            width={variant === "lead" ? 960 : 480}
            height={variant === "lead" ? 450 : 270}
            loading={variant === "lead" ? "eager" : "lazy"}
            className="absolute inset-0 size-full object-cover transition-transform duration-300 group-hover/story:scale-[1.015]"
            onError={() => {
              if (!thumbnailUrl) return;
              setFailedThumbnailUrls((current) => {
                const next = new Set(current);
                next.add(thumbnailUrl);
                return next;
              });
            }}
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
          "relative min-w-0 overflow-hidden p-3.5",
          variant === "lead" && "p-4 sm:p-5",
          variant === "supporting" && rendersThumbnail &&
            "lg:col-start-1 lg:row-start-1 lg:self-center lg:p-3",
          variant === "trending" && rendersThumbnail &&
            "col-start-1 row-start-1 p-3 pr-1",
        )}
      >
        <div
          className={cn(
            "mb-2 flex min-w-0 items-center gap-2 pr-8",
            variant === "supporting" && "lg:mb-1.5",
            variant === "trending" && "mb-1.5 pr-0",
          )}
        >
          {variant === "compact" && rank ? (
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
          {formattedDate ? (
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
            "[overflow-wrap:anywhere] font-bold leading-tight text-foreground underline-offset-4 group-hover/story:underline",
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
        {variant !== "trending" ? (
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
          </div>
        ) : null}
        {circleItem ? (
          <CircleSharerStrip
            sharers={circleItem.sharers}
            totalCount={circleItem.sharerCount}
            compact={variant === "compact" || variant === "supporting"}
          />
        ) : null}
        {variant !== "trending" ? (
          <div className="absolute bottom-2 right-2 flex items-center gap-1">
            {circleItem && circleActions ? (
              <button
                type="button"
                aria-label="Hide From Your Circle"
                title="Hide From Your Circle"
                className="inline-flex size-8 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground"
                onClick={(event) => {
                  event.stopPropagation();
                  circleActions.hide(circleItem.storyId);
                }}
              >
                <EyeOff className="size-4" />
              </button>
            ) : null}
            <EntryCardActionMenu entry={story} showWireFeedback />
          </div>
        ) : null}
      </div>
      {variant === "trending" ? (
        <div
          data-wire-trending-actions
          className="absolute right-2 top-2 flex items-center gap-1 opacity-60 transition-opacity [@media(hover:hover)]:opacity-0 group-hover/story:opacity-100 group-focus-within/story:opacity-100"
        >
          {circleItem && circleActions ? (
            <button
              type="button"
              aria-label="Hide From Your Circle"
              title="Hide From Your Circle"
              className="inline-flex size-8 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground"
              onClick={(event) => {
                event.stopPropagation();
                circleActions.hide(circleItem.storyId);
              }}
            >
              <EyeOff className="size-4" />
            </button>
          ) : null}
          <EntryCardActionMenu entry={story} showWireFeedback />
        </div>
      ) : null}
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
          rankingDiagnostics={
            isDevDebugUiEnabled()
              ? {
                  rank,
                  score:
                    story.wireItem?.rankingScore ??
                    (rank ? Math.max(0, 51 - rank) / 50 : undefined),
                  scoreKind: story.wireItem?.rankingScore != null
                    ? "Ranking Score"
                    : "Placement Score",
                }
              : undefined
          }
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
