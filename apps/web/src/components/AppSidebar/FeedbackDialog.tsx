"use client";

import { useEffect, useId, useState } from "react";
import { ExternalLink, MessageSquarePlus } from "lucide-react";

import { FeedbackPhotoPicker } from "@/components/AppSidebar/FeedbackPhotoPicker";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { SidebarMenuButton } from "@/components/ui/sidebar";
import { useAuth } from "@/hooks/useAuth";
import { usePDSClient } from "@/hooks/usePDSClient";
import { isDummyReaderDataEnabled } from "@/lib/dummyReaderData";
import {
  fetchUserInputBoardReference,
  LOCAL_USER_INPUT_TAGS,
  requireUserInputFeedbackScopes,
  USER_INPUT_BOARD_URL,
  type UserInputBoardReference,
  userInputDiscussionUrl,
} from "@/lib/userInputFeedback";

interface FeedbackResult {
  local: boolean;
  url: string;
}

export function FeedbackDialog() {
  const titleId = useId();
  const detailsId = useId();
  const client = usePDSClient();
  const { getOAuthSession } = useAuth();
  const localPreview = isDummyReaderDataEnabled();
  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState("");
  const [details, setDetails] = useState("");
  const [selectedTags, setSelectedTags] = useState<string[]>([]);
  const [photos, setPhotos] = useState<File[]>([]);
  const [board, setBoard] = useState<UserInputBoardReference | null>(null);
  const [tagsLoading, setTagsLoading] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<FeedbackResult | null>(null);

  function handleOpenChange(next: boolean) {
    setOpen(next);
    if (next) {
      setTitle("");
      setDetails("");
      setSelectedTags([]);
      setPhotos([]);
      setBoard(null);
      setTagsLoading(!localPreview);
      setSubmitting(false);
      setError(null);
      setResult(null);
    }
  }

  useEffect(() => {
    if (!open || localPreview) return;

    let cancelled = false;
    void fetchUserInputBoardReference()
      .then((nextBoard) => {
        if (!cancelled) setBoard(nextBoard);
      })
      .catch((caught) => {
        if (!cancelled) {
          console.warn("Feedback tags could not be loaded", caught);
        }
      })
      .finally(() => {
        if (!cancelled) setTagsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [localPreview, open]);

  function toggleTag(value: string) {
    setSelectedTags((current) =>
      current.includes(value)
        ? current.filter((tag) => tag !== value)
        : [...current, value]
    );
  }

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trimmedTitle = title.trim();
    const trimmedDetails = details.trim();
    if (!trimmedTitle || submitting) return;

    setError(null);
    setSubmitting(true);
    try {
      if (localPreview) {
        setResult({ local: true, url: USER_INPUT_BOARD_URL });
        return;
      }

      const oauth = getOAuthSession();
      if (!oauth || !client) throw new Error("Sign in to send feedback.");
      await requireUserInputFeedbackScopes(
        oauth,
        photos.map((photo) => photo.type)
      );
      const activeBoard = board ?? (await fetchUserInputBoardReference());
      const discussion = await client.createUserInputFeedback({
        board: activeBoard,
        title: trimmedTitle,
        ...(trimmedDetails ? { body: trimmedDetails } : {}),
        ...(selectedTags.length ? { tags: selectedTags } : {}),
        ...(photos.length ? { photos } : {}),
      });
      setResult({
        local: false,
        url: userInputDiscussionUrl(discussion.uri) ?? USER_INPUT_BOARD_URL,
      });
    } catch (caught) {
      console.error("Feedback submission failed", caught);
      setError(
        caught instanceof Error
          ? caught.message
          : "Feedback could not be sent. Try again."
      );
    } finally {
      setSubmitting(false);
    }
  }

  const availableTags = localPreview ? LOCAL_USER_INPUT_TAGS : (board?.tags ?? []);

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogTrigger
        render={
          <SidebarMenuButton type="button" tooltip="Send Feedback" />
        }
      >
        <MessageSquarePlus />
        <span>Feedback</span>
      </DialogTrigger>
      <DialogContent className="sm:max-w-lg">
        {result ? (
          <>
            <DialogHeader>
              <DialogTitle>
                {result.local ? "Feedback Previewed" : "Feedback Sent"}
              </DialogTitle>
              <DialogDescription>
                {result.local
                  ? "Local mode stays offline, so this was a preview and nothing was posted."
                  : "Thanks—your feedback was posted to The Social Wire’s UserInput board."}
              </DialogDescription>
            </DialogHeader>
            <DialogFooter>
              <DialogClose render={<Button type="button" variant="outline" />}>
                Close
              </DialogClose>
              <Button
                nativeButton={false}
                render={<a href={result.url} target="_blank" rel="noreferrer" />}
              >
                {result.local ? "View Feedback Board" : "View Feedback"}
                <ExternalLink />
              </Button>
            </DialogFooter>
          </>
        ) : (
          <>
            <DialogHeader>
              <DialogTitle>Send Feedback</DialogTitle>
              <DialogDescription>
                Share a bug, idea, or question with The Social Wire team. Your
                feedback will be public on {" "}
                <a href={USER_INPUT_BOARD_URL} target="_blank" rel="noreferrer">
                  UserInput
                </a>
                .
              </DialogDescription>
            </DialogHeader>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="space-y-1.5">
                <Label htmlFor={titleId}>Title</Label>
                <Input
                  id={titleId}
                  value={title}
                  onChange={(event) => setTitle(event.target.value)}
                  placeholder="What would you like us to know?"
                  autoFocus
                  required
                />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor={detailsId}>Details</Label>
                <textarea
                  id={detailsId}
                  value={details}
                  onChange={(event) => setDetails(event.target.value)}
                  placeholder="Add context, steps to reproduce, or what you expected…"
                  rows={6}
                  className="flex min-h-32 w-full resize-y rounded-xl border border-input bg-card/80 px-3 py-2 text-sm shadow-sm outline-none transition-colors placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/45 dark:bg-input/30"
                />
              </div>
              {tagsLoading || availableTags.length ? (
                <fieldset className="space-y-2">
                  <legend className="text-sm font-medium">Tags</legend>
                  <div className="flex flex-wrap gap-2">
                    {tagsLoading
                      ? ["tag-1", "tag-2", "tag-3"].map((key) => (
                          <span
                            key={key}
                            className="h-8 w-20 animate-pulse rounded-full bg-muted"
                            aria-hidden
                          />
                        ))
                      : availableTags.map((tag) => {
                          const selected = selectedTags.includes(tag.value);
                          return (
                            <Button
                              key={tag.value}
                              type="button"
                              size="sm"
                              variant={selected ? "secondary" : "outline"}
                              aria-pressed={selected}
                              onClick={() => toggleTag(tag.value)}
                              className="rounded-full"
                            >
                              {tag.label}
                            </Button>
                          );
                        })}
                  </div>
                </fieldset>
              ) : null}
              <FeedbackPhotoPicker
                photos={photos}
                onPhotosChange={setPhotos}
                disabled={submitting}
              />
              {localPreview ? (
                <p className="rounded-xl border border-border/70 bg-muted/45 px-3 py-2 text-sm text-muted-foreground">
                  Local mode is offline. Submit will preview the success state
                  without posting anything.
                </p>
              ) : null}
              {error ? (
                <p
                  className="rounded-xl border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive"
                  role="alert"
                >
                  {error}
                </p>
              ) : null}
              <DialogFooter>
                <DialogClose render={<Button type="button" variant="outline" />}>
                  Cancel
                </DialogClose>
                <Button type="submit" disabled={!title.trim() || submitting}>
                  {submitting ? "Sending…" : "Send Feedback"}
                </Button>
              </DialogFooter>
            </form>
          </>
        )}
      </DialogContent>
    </Dialog>
  );
}
