"use client";

import { type ReactNode, useState } from "react";
import {
  BookmarkPlus,
  Check,
  Heart,
  Link2,
  MessageSquareQuote,
  Reply,
  Repeat,
} from "lucide-react";
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
import {
  useEntryIsLatrSaved,
  useSaveReadLaterEntryMutation,
} from "@/hooks/useLatrSaved";
import type { EntryDetail } from "@/lib/atprotoClient";
import { canonicalArticleHttpsUrl } from "@/lib/articleCanonicalUrl";
import { cn } from "@/lib/utils";

function shareArticleUrl(entry: EntryDetail): string {
  const canon = canonicalArticleHttpsUrl(entry);
  return canon ?? "";
}

interface ArticleSocialToolbarProps {
  entry: EntryDetail | null;
  className?: string;
  showReadLaterSave?: boolean;
  extraActions?: ReactNode;
}

export function ArticleSocialToolbar({
  entry,
  className,
  showReadLaterSave = true,
  extraActions,
}: ArticleSocialToolbarProps) {
  const {
    viewerQuery,
    toggleLikeMutation,
    toggleRepostMutation,
    quoteMutation,
    replyMutation,
    hasLinkedPost,
  } = useEntrySocial(entry);

  const canonUrl = entry ? canonicalArticleHttpsUrl(entry) : null;
  const alreadyLatrSaved = useEntryIsLatrSaved(entry?.entryId ?? "", canonUrl ?? null);
  const saveLaterMut = useSaveReadLaterEntryMutation();

  const [repostOpen, setRepostOpen] = useState(false);
  const [quoteOpen, setQuoteOpen] = useState(false);
  const [replyOpen, setReplyOpen] = useState(false);
  const [quoteText, setQuoteText] = useState("");
  const [replyText, setReplyText] = useState("");

  const likeUri = viewerQuery.data?.likeUri;
  const repostUri = viewerQuery.data?.repostUri;
  const liked = !!likeUri;
  const reposted = !!repostUri;

  const busySocial =
    toggleLikeMutation.isPending ||
    toggleRepostMutation.isPending ||
    replyMutation.isPending ||
    viewerQuery.isLoading;

  const disabledHint = hasLinkedPost
    ? undefined
    : "Like, Reply, and Repost need a Bluesky post linked to this article.";

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

  const submitReply = () => {
    const text = replyText.trim();
    if (!text) return;
    replyMutation.mutate(text, {
      onSuccess: () => {
        setReplyOpen(false);
        setReplyText("");
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

  if (!entry) return null;

  return (
    <>
      <div
        className={cn(
          "-mx-1 w-full border-b border-border pb-3 mb-2 sm:-mx-0 sm:pb-3.5 sm:mb-3 md:mb-1 md:pb-2",
          "max-md:fixed max-md:inset-x-0 max-md:bottom-0 max-md:z-40 max-md:mx-0 max-md:mb-0 max-md:flex max-md:w-screen max-md:flex-nowrap max-md:items-center max-md:gap-2 max-md:overflow-x-auto max-md:border-b-0 max-md:border-t max-md:bg-background/95 max-md:px-3 max-md:pt-2 max-md:pb-[calc(env(safe-area-inset-bottom)+2.5rem)] max-md:shadow-[0_-16px_36px_-28px_oklch(0_0_0/0.55)] max-md:backdrop-blur-md max-md:[scrollbar-width:none] max-md:[&::-webkit-scrollbar]:hidden",
          "max-md:[&>button]:h-11 max-md:[&>button]:min-h-[44px] max-md:[&>button]:min-w-[44px] max-md:[&>button]:flex-1 max-md:[&>button]:basis-0 max-md:[&>button]:px-0",
          "max-md:[&>a]:h-11 max-md:[&>a]:min-h-[44px] max-md:[&>a]:min-w-[44px] max-md:[&>a]:flex-1 max-md:[&>a]:basis-0 max-md:[&>a]:px-0",
          "md:flex md:flex-wrap md:items-center md:gap-2",
          className
        )}
        role="toolbar"
        aria-label="Article Sharing and Reactions"
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
          <span className="sr-only text-xs font-medium md:not-sr-only md:text-sm">
            {liked ? "Unlike" : "Like"}
          </span>
        </Button>

        <Button
          variant="outline"
          size="sm"
          disabled={!hasLinkedPost || busySocial}
          className="h-11 min-h-[44px] justify-center gap-1.5 px-2 sm:h-7 sm:min-h-0 sm:justify-start sm:px-2.5"
          title={!hasLinkedPost ? disabledHint : "Reply"}
          onClick={() => setReplyOpen(true)}
        >
          <Reply className="size-5 shrink-0 sm:size-3.5" />
          <span className="sr-only text-xs font-medium md:not-sr-only md:text-sm">Reply</span>
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
                ? "Undo Repost"
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
          <span className="sr-only text-xs font-medium md:not-sr-only md:text-sm">
            {reposted ? "Undo Repost" : "Repost"}
          </span>
        </Button>

        <Button
          variant="outline"
          size="sm"
          className="h-11 min-h-[44px] justify-center gap-1.5 px-2 sm:h-7 sm:min-h-0 sm:justify-start sm:px-2.5"
          title="Quote Post"
          onClick={() => setQuoteOpen(true)}
        >
          <MessageSquareQuote className="size-5 shrink-0 sm:size-3.5" />
          <span className="sr-only text-xs font-medium md:not-sr-only md:text-sm">Quote</span>
        </Button>

        {showReadLaterSave && canonUrl ? (
          <Button
            variant={alreadyLatrSaved ? "secondary" : "outline"}
            size="sm"
            disabled={busySocial || alreadyLatrSaved || !canonUrl}
            className="h-11 min-h-[44px] justify-center gap-1.5 px-2 sm:h-7 sm:min-h-0 sm:justify-start sm:px-2.5"
            title={
              alreadyLatrSaved
                ? "Already in Read Later"
                : "Save Original Article to Read Later"
            }
            onClick={() => {
              saveLaterMut.mutate({
                entryId: entry.entryId,
                url: canonUrl ?? undefined,
                title: entry.title?.trim() || undefined,
              });
            }}
          >
            {alreadyLatrSaved ? (
              <Check className="size-5 shrink-0 text-emerald-600 sm:size-3.5" />
            ) : (
              <BookmarkPlus className="size-5 shrink-0 sm:size-3.5" />
            )}
            <span className="sr-only text-xs font-medium md:not-sr-only md:text-sm">
              {alreadyLatrSaved ? "Saved" : "Save"}
            </span>
          </Button>
        ) : null}

        {canonUrl ? (
          <a
            href={shareArticleUrl(entry)}
            target="_blank"
            rel="noopener noreferrer"
            className={cn(
              buttonVariants({ variant: "outline", size: "sm" }),
              "inline-flex h-11 min-h-[44px] items-center justify-center gap-1 px-2 no-underline sm:h-7 sm:min-h-0 sm:justify-start sm:gap-1.5 sm:px-2.5"
            )}
            title="Open Canonical Article"
            aria-label="Open Canonical Article in New Tab"
          >
            <Link2 className="size-5 shrink-0 sm:size-3.5" />
            <span className="sr-only max-w-[5rem] truncate text-xs font-medium md:not-sr-only md:max-w-[9rem] md:text-sm">
              Link
            </span>
          </a>
        ) : null}

        {extraActions}

        {!hasLinkedPost ? (
          <p className="w-full text-[11px] leading-snug text-muted-foreground max-md:hidden sm:text-xs">
            Like, Reply, and Repost need a Bluesky post linked to this article.
            Quote works here.
          </p>
        ) : null}
      </div>

      <Dialog open={repostOpen} onOpenChange={setRepostOpen}>
        <DialogContent showCloseButton className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Repost This Article?</DialogTitle>
            <DialogDescription>
              This repeats the linked Bluesky post to your followers. You can
              undo a repost anytime from this toolbar.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter className="mx-0 mb-0 grid grid-cols-2 gap-2 border-0 bg-transparent p-0 pt-2 sm:flex sm:flex-row sm:justify-end">
            <Button
              variant="outline"
              size="sm"
              className="min-w-24"
              onClick={() => setRepostOpen(false)}
            >
              Cancel
            </Button>
            <Button
              size="sm"
              className="min-w-24"
              disabled={toggleRepostMutation.isPending}
              onClick={confirmRepost}
            >
              Repost
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={replyOpen} onOpenChange={setReplyOpen}>
        <DialogContent showCloseButton className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Reply</DialogTitle>
            <DialogDescription>
              Posts a reply to the Bluesky conversation for this article.
            </DialogDescription>
          </DialogHeader>
          <div className="grid gap-2 py-2">
            <Label htmlFor="reply-text">Reply</Label>
            <textarea
              id="reply-text"
              value={replyText}
              onChange={(e) => setReplyText(e.target.value)}
              placeholder="Write a reply..."
              rows={4}
              className="flex min-h-[100px] w-full resize-y rounded-lg border border-input bg-transparent px-2.5 py-2 text-sm outline-none transition-colors placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 dark:bg-input/30"
            />
          </div>
          <DialogFooter className="mx-0 mb-0 grid grid-cols-2 gap-2 border-0 bg-transparent p-0 pt-2 sm:flex sm:flex-row sm:justify-end">
            <Button
              variant="outline"
              size="sm"
              className="min-w-24"
              onClick={() => setReplyOpen(false)}
            >
              Cancel
            </Button>
            <Button
              size="sm"
              className="min-w-28"
              disabled={!replyText.trim() || replyMutation.isPending}
              onClick={submitReply}
            >
              Post Reply
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
                ? "Shares your comment with the Bluesky post for this article."
                : "Shares your comment with a link card for the original article."}
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
          <DialogFooter className="mx-0 mb-0 grid grid-cols-2 gap-2 border-0 bg-transparent p-0 pt-2 sm:flex sm:flex-row sm:justify-end">
            <Button
              variant="outline"
              size="sm"
              className="min-w-24"
              onClick={() => setQuoteOpen(false)}
            >
              Cancel
            </Button>
            <Button
              size="sm"
              className="min-w-28"
              disabled={!quoteText.trim() || quoteMutation.isPending}
              onClick={submitQuote}
            >
              Post Quote
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
