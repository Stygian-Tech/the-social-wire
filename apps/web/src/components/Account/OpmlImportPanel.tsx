"use client";

import { useId, useMemo, useState } from "react";
import { CheckCircle2, FileUp, Loader2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
  buildOpmlImportReview,
  MAX_OPML_FILE_BYTES,
  parseOpmlFeeds,
  type OpmlImportBatchResult,
  type OpmlImportProgress,
  type ParsedOpmlFeed,
} from "@/lib/opmlImport";
import { cn } from "@/lib/utils";

interface OpmlImportPanelProps {
  existingFeedUrls: readonly string[];
  existingSubscriptionsLoading: boolean;
  existingSubscriptionsError?: string | null;
  onImport: (
    feeds: readonly ParsedOpmlFeed[],
    onProgress: (progress: OpmlImportProgress) => void
  ) => Promise<OpmlImportBatchResult>;
}

function importedSummary(result: OpmlImportBatchResult): string {
  const imported = `${result.imported.length} ${result.imported.length === 1 ? "Feed" : "Feeds"} Imported`;
  if (result.skippedExisting.length === 0) return imported;
  return `${imported} · ${result.skippedExisting.length} Already Subscribed`;
}

export function OpmlImportPanel({
  existingFeedUrls,
  existingSubscriptionsLoading,
  existingSubscriptionsError = null,
  onImport,
}: OpmlImportPanelProps) {
  const inputId = useId();
  const [fileName, setFileName] = useState("");
  const [parsedFeeds, setParsedFeeds] = useState<ParsedOpmlFeed[]>([]);
  const [selectedUrls, setSelectedUrls] = useState<Set<string>>(() => new Set());
  const [parseError, setParseError] = useState<string | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [result, setResult] = useState<OpmlImportBatchResult | null>(null);
  const [progress, setProgress] = useState<OpmlImportProgress | null>(null);
  const [pending, setPending] = useState(false);

  const review = useMemo(
    () => buildOpmlImportReview(parsedFeeds, existingFeedUrls),
    [existingFeedUrls, parsedFeeds]
  );
  const availableFeeds = useMemo(
    () => review.candidates.filter((feed) => feed.status === "available"),
    [review.candidates]
  );
  const alreadySubscribedCount =
    review.candidates.length - availableFeeds.length;
  const selectedFeeds = availableFeeds.filter((feed) => selectedUrls.has(feed.feedUrl));
  const importComplete =
    result !== null &&
    result.failed.length === 0 &&
    result.imported.length + result.skippedExisting.length > 0;

  function resetImport() {
    setFileName("");
    setParsedFeeds([]);
    setSelectedUrls(new Set());
    setParseError(null);
    setImportError(null);
    setResult(null);
    setProgress(null);
  }

  async function loadFile(file: File | undefined) {
    setParseError(null);
    setImportError(null);
    setResult(null);
    setProgress(null);
    setParsedFeeds([]);
    setSelectedUrls(new Set());
    setFileName(file?.name ?? "");
    if (!file) return;

    if (file.size > MAX_OPML_FILE_BYTES) {
      setParseError("Choose an OPML file smaller than 2 MB.");
      return;
    }

    try {
      const feeds = parseOpmlFeeds(await file.text());
      if (feeds.length === 0) {
        throw new Error("This OPML file does not contain any valid RSS or Atom feed URLs.");
      }
      const nextReview = buildOpmlImportReview(feeds, existingFeedUrls);
      setParsedFeeds(feeds);
      setSelectedUrls(
        new Set(
          nextReview.candidates
            .filter((feed) => feed.status === "available")
            .map((feed) => feed.feedUrl)
        )
      );
    } catch (error) {
      setParseError(
        error instanceof Error ? error.message : "Could not read this OPML file."
      );
    }
  }

  async function importSelected() {
    if (pending || selectedFeeds.length === 0) return;
    setPending(true);
    setImportError(null);
    setResult(null);
    setProgress(null);
    try {
      const nextResult = await onImport(selectedFeeds, setProgress);
      setResult(nextResult);
      setSelectedUrls(
        new Set(nextResult.failed.map(({ feed }) => feed.feedUrl))
      );
    } catch (error) {
      setImportError(
        error instanceof Error ? error.message : "Could not import these feeds."
      );
    } finally {
      setPending(false);
    }
  }

  if (importComplete && result) {
    return (
      <div className="space-y-4 py-2 text-center" role="status">
        <CheckCircle2 className="mx-auto size-10 text-primary" aria-hidden />
        <div>
          <h3 className="text-base font-semibold text-foreground">
            {importedSummary(result)}
          </h3>
          <p className="mt-1 text-sm text-muted-foreground">
            Your subscriptions are saved on your PDS and will appear in the sidebar.
          </p>
          {result.skippedExisting.length > 0 ? (
            <p className="mt-1 text-xs text-muted-foreground">
              {result.skippedExisting.length} became already subscribed before import and were skipped.
            </p>
          ) : null}
        </div>
        <div className="flex justify-center">
          <Button type="button" onClick={resetImport}>
            Import Another OPML File
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div>
        <h3 className="text-sm font-bold text-foreground">OPML File</h3>
        <p className="mt-1 text-xs text-muted-foreground">
          Existing subscriptions are checked before you choose feeds to import.
        </p>
      </div>

      {existingSubscriptionsLoading ? (
        <p className="flex items-center gap-2 text-sm text-muted-foreground" role="status">
          <Loader2 className="size-4 animate-spin" aria-hidden />
          Checking Existing Subscriptions…
        </p>
      ) : existingSubscriptionsError ? (
        <p className="text-sm text-destructive" role="alert">
          {existingSubscriptionsError}
        </p>
      ) : (
        <div className="flex flex-wrap items-center gap-2">
        <Input
          id={inputId}
          type="file"
          accept=".opml,.xml,text/x-opml,application/xml,text/xml"
          className="peer sr-only"
          disabled={pending}
          onChange={(event) => {
            const input = event.currentTarget;
            void loadFile(input.files?.[0]);
            input.value = "";
          }}
        />
        <Label
          htmlFor={inputId}
          aria-disabled={pending}
          className="inline-flex h-8 cursor-pointer items-center gap-1 rounded-xl border border-border bg-card/90 px-3 text-[0.8rem] font-semibold shadow-sm transition-colors hover:bg-muted peer-focus-visible:border-ring peer-focus-visible:ring-[3px] peer-focus-visible:ring-ring/50 aria-disabled:pointer-events-none aria-disabled:opacity-50"
        >
          <FileUp className="size-3.5" aria-hidden />
          Choose OPML File
        </Label>
        {fileName ? (
          <span className="max-w-56 truncate text-xs text-muted-foreground">{fileName}</span>
        ) : (
          <span className="text-xs text-muted-foreground">Up to 2 MB</span>
        )}
        </div>
      )}

      {parseError ? (
        <p className="text-sm text-destructive" role="alert">{parseError}</p>
      ) : null}

      {review.candidates.length > 0 ? (
        <>
          <p className="text-xs text-muted-foreground" aria-live="polite">
            {availableFeeds.length} New · {alreadySubscribedCount} Already Subscribed
            {review.duplicateCount > 0 ? ` · ${review.duplicateCount} Duplicate ${review.duplicateCount === 1 ? "Feed" : "Feeds"} Removed` : ""}
          </p>

          <div className="flex flex-wrap items-center gap-2">
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={pending || availableFeeds.length === 0}
              onClick={() => setSelectedUrls(new Set(availableFeeds.map((feed) => feed.feedUrl)))}
            >
              Select All
            </Button>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              disabled={pending || selectedUrls.size === 0}
              onClick={() => setSelectedUrls(new Set())}
            >
              Clear Selection
            </Button>
            <span className="ml-auto text-xs text-muted-foreground" aria-live="polite">
              {selectedFeeds.length} Selected
            </span>
          </div>

          <fieldset disabled={pending}>
            <legend className="sr-only">Feeds To Import</legend>
            <ScrollArea className="h-[min(45svh,24rem)] rounded-xl border border-border/70">
              <ul className="space-y-1 p-2" aria-label="OPML Feeds">
                {review.candidates.map((feed) => {
                  const checkboxId = `${inputId}-${feed.sourceIndex}`;
                  const subscribed = feed.status === "already-subscribed";
                  const checked = !subscribed && selectedUrls.has(feed.feedUrl);
                  return (
                    <li
                      key={feed.feedUrl}
                      className={cn(
                        "rounded-xl border border-border/70 bg-muted/35 px-3 py-2",
                        checked && "border-[var(--purple-border-strong)] bg-[var(--purple-surface)]"
                      )}
                    >
                      <div className="flex items-start gap-2.5">
                        <input
                          id={checkboxId}
                          type="checkbox"
                          checked={checked}
                          disabled={subscribed || pending}
                          className="mt-0.5 size-4 shrink-0 accent-primary"
                          onChange={(event) => {
                            setSelectedUrls((current) => {
                              const next = new Set(current);
                              if (event.target.checked) next.add(feed.feedUrl);
                              else next.delete(feed.feedUrl);
                              return next;
                            });
                          }}
                        />
                        <label htmlFor={checkboxId} className={cn("min-w-0 flex-1", subscribed ? "cursor-not-allowed" : "cursor-pointer")}>
                          <span className="flex flex-wrap items-center justify-between gap-2">
                            <span className="text-sm font-medium text-foreground">{feed.title}</span>
                            {subscribed ? (
                              <span className="text-[11px] font-semibold text-muted-foreground">Already Subscribed</span>
                            ) : null}
                          </span>
                          <span className="mt-0.5 block break-all text-xs text-muted-foreground">{feed.feedUrl}</span>
                          {feed.categoryPath.length > 0 ? (
                            <span className="mt-1 block text-[11px] text-muted-foreground/80">{feed.categoryPath.join(" / ")}</span>
                          ) : null}
                        </label>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </ScrollArea>
          </fieldset>
        </>
      ) : null}

      {pending && progress ? (
        <p className="flex items-center gap-2 text-sm text-muted-foreground" role="status">
          <Loader2 className="size-4 animate-spin" aria-hidden />
          Importing {progress.completed} of {progress.total}…
        </p>
      ) : null}

      {result && result.failed.length > 0 ? (
        <div className="space-y-1 text-sm" role="alert">
          <p className="font-medium text-foreground">{importedSummary(result)}</p>
          <p className="text-destructive">
            {result.failed.length} {result.failed.length === 1 ? "feed" : "feeds"} could not be imported. They remain selected so you can retry.
          </p>
        </div>
      ) : null}
      {importError ? <p className="text-sm text-destructive" role="alert">{importError}</p> : null}

      <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <Button
          type="button"
          disabled={pending || selectedFeeds.length === 0 || existingSubscriptionsLoading}
          onClick={() => void importSelected()}
        >
          {pending
            ? progress
              ? `Importing ${progress.completed} of ${progress.total}…`
              : "Importing…"
            : result?.failed.length
              ? `Retry ${selectedFeeds.length} ${selectedFeeds.length === 1 ? "Feed" : "Feeds"}`
              : `Import ${selectedFeeds.length} ${selectedFeeds.length === 1 ? "Feed" : "Feeds"}`}
        </Button>
      </div>
    </div>
  );
}
