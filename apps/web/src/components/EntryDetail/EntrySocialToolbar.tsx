"use client";

import { useCallback, useState } from "react";
import {
  Heart,
  Link2,
  MessageSquareQuote,
  Repeat,
  Share2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
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
import { cn } from "@/lib/utils";

function shareArticleUrl(entry: EntryDetail): string {
  return (
    entry.embedUrl ??
    entry.originalUrl ??
    (typeof window !== "undefined" ? window.location.href : "")
  );
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
  const [shareHint, setShareHint] = useState<string | null>(null);

  const likeUri = viewerQuery.data?.likeUri;
  const repostUri = viewerQuery.data?.repostUri;
  const liked = !!likeUri;
  const reposted = !!repostUri;

  const busySocial =
    toggleLikeMutation.isPending ||
    toggleRepostMutation.isPending ||
    viewerQuery.isLoading;

  const onShare = useCallback(async () => {
    const url = shareArticleUrl(entry);
    const title = entry.title;
    setShareHint(null);

    if (navigator.share) {
      try {
        await navigator.share({
          title,
          text: title,
          url,
        });
        return;
      } catch (err) {
        if ((err as Error).name === "AbortError") return;
      }
    }

    try {
      await navigator.clipboard.writeText(url);
      setShareHint("Link copied");
      window.setTimeout(() => setShareHint(null), 2000);
    } catch {
      setShareHint("Could not copy link");
      window.setTimeout(() => setShareHint(null), 2500);
    }
  }, [entry]);

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
          "flex flex-wrap items-center gap-2 border-b pb-4 mb-6",
          className
        )}
      >
        <Button
          variant={liked ? "secondary" : "outline"}
          size="sm"
          disabled={!hasLinkedPost || busySocial}
          className="gap-1.5"
          title={!hasLinkedPost ? disabledHint : undefined}
          onClick={() =>
            toggleLikeMutation.mutate({
              likeUri,
            })
          }
        >
          <Heart
            className={cn("size-4", liked && "fill-current text-red-600")}
          />
          {liked ? "Unlike" : "Like"}
        </Button>

        <Button
          variant={reposted ? "secondary" : "outline"}
          size="sm"
          disabled={!hasLinkedPost || busySocial}
          className="gap-1.5"
          title={!hasLinkedPost ? disabledHint : undefined}
          onClick={() => {
            if (reposted) {
              toggleRepostMutation.mutate({ repostUri });
            } else {
              setRepostOpen(true);
            }
          }}
        >
          <Repeat className="size-4" />
          {reposted ? "Undo repost" : "Repost"}
        </Button>

        <Button
          variant="outline"
          size="sm"
          className="gap-1.5"
          onClick={() => setQuoteOpen(true)}
        >
          <MessageSquareQuote className="size-4" />
          Quote
        </Button>

        <Button
          variant="outline"
          size="sm"
          className="gap-1.5"
          onClick={onShare}
        >
          <Share2 className="size-4" />
          Share
        </Button>

        {(entry.embedUrl ?? entry.originalUrl) ? (
          <a
            href={shareArticleUrl(entry)}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
          >
            <Link2 className="size-3.5" />
            Canonical link
          </a>
        ) : null}

        {shareHint ? (
          <span className="text-xs text-muted-foreground" role="status">
            {shareHint}
          </span>
        ) : null}

        {!hasLinkedPost ? (
          <p className="w-full text-[11px] leading-snug text-muted-foreground">
            Quote and Share work from here; Like/Repost require a Bluesky post
            referenced by{" "}
            <code className="rounded bg-muted px-1 py-0.5 text-[10px]">
              bskyPostRef
            </code>{" "}
            on the article record.
          </p>
        ) : null}
      </div>

      <Dialog open={repostOpen} onOpenChange={setRepostOpen}>
        <DialogContent showCloseButton className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Repost this article?</DialogTitle>
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
            <DialogTitle>Quote post</DialogTitle>
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
