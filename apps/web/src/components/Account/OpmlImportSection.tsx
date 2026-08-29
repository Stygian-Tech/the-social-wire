"use client";

import { useMemo } from "react";

import {
  useImportOpmlFeedSubscriptions,
  useSkyreaderFeedSubscriptions,
} from "@/hooks/usePublications";
import { OpmlImportPanel } from "./OpmlImportPanel";

export function OpmlImportSection() {
  const importOpmlFeeds = useImportOpmlFeedSubscriptions();
  const skyreaderSubscriptions = useSkyreaderFeedSubscriptions();
  const existingFeedUrls = useMemo(
    () =>
      (skyreaderSubscriptions.data ?? []).flatMap((row) => {
        const sourceType = row.value.sourceType?.trim().toLowerCase();
        const feedUrl = row.value.feedUrl?.trim();
        return feedUrl && (!sourceType || sourceType === "rss") ? [feedUrl] : [];
      }),
    [skyreaderSubscriptions.data]
  );

  return (
    <section
      id="opml-import"
      className="flex scroll-mt-16 flex-col border-t p-4 md:p-6"
      aria-labelledby="opml-import-heading"
    >
      <div className="mx-auto flex w-full max-w-2xl flex-col gap-6">
        <header>
          <h2
            id="opml-import-heading"
            className="text-xl font-black tracking-tight"
          >
            Import OPML Feeds
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Upload an OPML export, review its feeds, and choose which new
            subscriptions to save.
          </p>
        </header>
        <div className="rounded-2xl border bg-card p-4 shadow-[var(--soft-elevation)] sm:p-5">
          <OpmlImportPanel
            existingFeedUrls={existingFeedUrls}
            existingSubscriptionsLoading={skyreaderSubscriptions.isLoading}
            existingSubscriptionsError={
              skyreaderSubscriptions.error
                ? "Could not load your existing subscriptions. Refresh the account page to try again."
                : null
            }
            onImport={(feeds, onProgress) =>
              importOpmlFeeds.mutateAsync({ feeds, onProgress })
            }
          />
        </div>
      </div>
    </section>
  );
}
