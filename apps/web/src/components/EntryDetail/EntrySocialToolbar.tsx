"use client";

import { useState } from "react";
import { Heart, Link2, MessageSquareQuote, Repeat } from "lucide-react";
import { Button, buttonVariants } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { useEntrySocial } from "@/hooks/useEntrySocial";
import type { EntryDetail } from "@/lib/atprotoClient";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";
import { cn } from "@/lib/utils";

function shareArticleUrl(entry: EntryDetail): string {
  const raw =
    entry.embedUrl ??
    entry.originalUrl ??
    (typeof window !== "undefined" ? window.location.href : "");
  if (raw.startsWith("http://") || raw.startsWith("https://")) {
    return normalizeHttpUrlToHttps(raw);
  }
  return raw;
}

interface EntrySocialToolbarProps {
  entry: EntryDetail;
  className?: string;
}

export function EntrySocialToolbar({
  entry,
  className,
}: EntrySocialToolbarProps) {
  const {
    viewerQuery,
    toggleLikeMutation,
    toggleRepostMutation,
    quoteMutation,
    hasLinkedPost,
  } = useEntrySocial(entry);

  const [repostOpen, setRepostOpen] = useState(false);
  const [quoteOpen, setQuoteOpen] = useState(false);
  const [quoteText, setQuoteText] = useState("");

  const likeUri = viewerQuery.data?.likeUri;
  const repostUri = viewerQuery.data?.repostUri;
  const liked = !!likeUri;
  const reposted = !!repostUri;

  const busySocial =
    toggleLikeMutation.isPending ||
    toggleRepostMutation.isPending ||
    viewerQuery.isLoading;

  const disabledHint = hasLinkedPost
    ? undefined
    : "No Bluesky post is linked on this record (bskyPostRef). Like and Repost need a linked app.bsky.feed.post.";

  const submitQuote = () => {
    const text = quoteText.trim();
    if (!text) return;
    quoteMutation.mutate(text, {
      onSuccess: () => {
        setQuoteOpen(false);
        setQuoteText("");
      },
    });
  };

  const confirmRepost = () => {
    toggleRepostMutation.mutate(
      { repostUri },
      {
        onSuccess: () => setRepostOpen(false),
      }
    );
  };

  return (
    <>
      <div
        className={cn(
          "-mx-1 flex flex-wrap items-center gap-1 border-b border-border pb-3 mb-4 sm:-mx-0 sm:gap-2 sm:pb-3.5 sm:mb-6",
          className
        )}
        role="toolbar"
        aria-label="Article sharing and reactions"
      >
        <Button
          variant={liked ? "secondary" : "outline"}
          size="sm"
          disabled={!hasLinkedPost || busySocial}
          className="h-11 min-h-[44px] justify-center gap-1.5 px-2 sm:h-7 sm:min-h-0 sm:justify-start sm:px-2.5"
          title={!hasLinkedPost ? disabledHint : liked ? "Unlike" : "Like"}
          onClick={() =>
            toggleLikeMutation.mutate({
              likeUri,
            })
          }
        >
          <Heart
            className={cn("size-5 shrink-0 sm:size-3.5", liked && "fill-current text-red-600")}
          />
          <span className="text-xs font-medium sm:text-sm">
            {liked ? "Unlike" : "Like"}
          </span>
        </Button>

        <Button
          variant={reposted ? "secondary" : "outline"}
          size="sm"
          disabled={!hasLinkedPost || busySocial}
          className="h-11 min-h-[44px] justify-center gap-1.5 px-2 sm:h-7 sm:min-h-0 sm:justify-start sm:px-2.5"
          title={
            !hasLinkedPost
              ? disabledHint
              : reposted
                ? "Undo repost"
                : "Repost"
          }
          onClick={() => {
            if (reposted) {
              toggleRepostMutation.mutate({ repostUri });
            } else {
              setRepostOpen(true);
            }
          }}
        >
          <Repeat className="size-5 shrink-0 sm:size-3.5" />
          <span className="text-xs font-medium sm:text-sm">
            {reposted ? "Undo repost" : "Repost"}
          </span>
        </Button>

        <Button
          variant="outline"
          size="sm"
          className="h-11 min-h-[44px] justify-center gap-1.5 px-2 sm:h-7 sm:min-h-0 sm:justify-start sm:px-2.5"
          title="Quote post"
          onClick={() => setQuoteOpen(true)}
        >
          <MessageSquareQuote className="size-5 shrink-0 sm:size-3.5" />
          <span className="text-xs font-medium sm:text-sm">Quote</span>
        </Button>

        {(entry.embedUrl ?? entry.originalUrl) ? (
          <a
            href={shareArticleUrl(entry)}
            target="_blank"
            rel="noopener noreferrer"
            className={cn(
              buttonVariants({ variant: "outline", size: "sm" }),
              "inline-flex h-11 min-h-[44px] items-center justify-center gap-1 px-2 no-underline sm:h-7 sm:min-h-0 sm:justify-start sm:gap-1.5 sm:px-2.5"
            )}
            title="Open canonical article"
            aria-label="Open canonical article in new tab"
          >
            <Link2 className="size-5 shrink-0 sm:size-3.5" />
            <span className="max-w-[5rem] truncate text-xs font-medium sm:max-w-[9rem] sm:text-sm">
              Link
            </span>
          </a>
        ) : null}

        {!hasLinkedPost ? (
          <p className="w-full text-[11px] leading-snug text-muted-foreground sm:text-xs">
            Like/Repost need a linked Bluesky post (
            <code className="rounded bg-muted px-1 py-0.5 text-[10px]">
              bskyPostRef
            </code>
            ). Quote works here.
          </p>
        ) : null}
      </div>

      <Dialog open={repostOpen} onOpenChange={setRepostOpen}>
        <DialogContent showCloseButton className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Repost this Article?</DialogTitle>
            <DialogDescription>
              This repeats the linked Bluesky post to your followers. You can
              undo a repost anytime from this toolbar.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="flex flex-row justify-end gap-2 border-0 bg-transparent p-0 pt-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setRepostOpen(false)}
            >
              Cancel
            </Button>
            <Button
              size="sm"
              disabled={toggleRepostMutation.isPending}
              onClick={confirmRepost}
            >
              Repost
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={quoteOpen} onOpenChange={setQuoteOpen}>
        <DialogContent showCloseButton className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Quote Post</DialogTitle>
            <DialogDescription>
              {hasLinkedPost
                ? "Posts a quote of the linked Bluesky record."
                : "Posts your text with an external link card to this article's canonical URL."}
            </DialogDescription>
          </DialogHeader>
          <div className="grid gap-2 py-2">
            <Label htmlFor="quote-text">Comment</Label>
            <textarea
              id="quote-text"
              value={quoteText}
              onChange={(e) => setQuoteText(e.target.value)}
              placeholder="Add your thoughts..."
              rows={4}
              className="flex min-h-[100px] w-full resize-y rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm outline-none transition-colors placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
            />
          </div>
          <DialogFooter className="flex flex-row justify-end gap-2 border-0 bg-transparent p-0 pt-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setQuoteOpen(false)}
            >
              Cancel
            </Button>
            <Button
              size="sm"
              disabled={!quoteText.trim() || quoteMutation.isPending}
              onClick={submitQuote}
            >
              Post quote
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
