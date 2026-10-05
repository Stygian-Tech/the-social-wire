"use client";

import { useMemo, useState } from "react";

import {
  useImportOpmlFeedSubscriptions,
  useSkyreaderFeedSubscriptions,
} from "@/hooks/usePublications";
import { ChevronDown } from "lucide-react";
import { useImportOpmlPodcasts } from "@/hooks/useImportOpmlPodcasts";
import { useAuth } from "@/hooks/useAuth";
import { podcastsEnabled } from "@/lib/podcasts/playback";
import { OpmlImportPanel } from "./OpmlImportPanel";

export function OpmlImportSection() {
  const { session } = useAuth();
  return <OpmlViewerImportSection key={session?.did ?? "signed-out"} />;
}
function OpmlViewerImportSection() {
  const [destination, setDestination] = useState("publications");
  const [privateFeeds, setPrivateFeeds] = useState(false);
  const [pending, setPending] = useState(false);
  const { session } = useAuth();
  const podcastImport = useImportOpmlPodcasts(podcastsEnabled() && destination === "podcasts");
  const importingPodcasts = podcastsEnabled() && destination === "podcasts";
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
          {podcastsEnabled() ? (
            <div className="mb-5 space-y-3">
              <label className="block space-y-1 text-sm font-medium">
                <span>Import To</span>
                <span className="relative block">
                  <select value={destination} disabled={pending} onChange={(event) => setDestination(event.target.value)} className="min-h-11 w-full appearance-none rounded-lg border bg-background pl-3 pr-9">
                    <option value="publications">Publications</option>
                    <option value="podcasts">Podcasts</option>
                  </select>
                  <ChevronDown className="pointer-events-none absolute right-3 top-1/2 size-4 -translate-y-1/2" aria-hidden />
                </span>
              </label>
              {importingPodcasts ? <>
                <label className="flex min-h-9 items-center gap-2 text-sm"><input type="checkbox" checked={privateFeeds} disabled={pending} onChange={(event) => setPrivateFeeds(event.target.checked)} />Private Feeds</label>
                <p className="text-xs text-muted-foreground">{privateFeeds ? "Saved privately to your account. No public subscription records are created." : "Import audio podcasts. Public subscriptions are saved on your PDS. For paid or tokenized feeds, choose Private Feeds."}</p>
              </> : null}
            </div>
          ) : null}
          <OpmlImportPanel
            key={`${session?.did ?? "signed-out"}:${destination}:${privateFeeds}`}
            onPendingChange={setPending}
            successDescription={importingPodcasts ? "Your podcasts will appear in Podcasts under Subscribed Shows." : undefined}
            existingFeedUrls={importingPodcasts ? (podcastImport.existing.data ?? []).flatMap((show) => {
              const isPrivate = show.visibility === "private" || show.sourceKind === "private-rss";
              return isPrivate === privateFeeds && show.feedUrl ? [show.feedUrl] : [];
            }) : existingFeedUrls}
            existingSubscriptionsLoading={importingPodcasts ? podcastImport.existing.isLoading : skyreaderSubscriptions.isLoading}
            existingSubscriptionsError={
              (importingPodcasts ? podcastImport.existing.error : skyreaderSubscriptions.error)
                ? "Could not load your existing subscriptions. Refresh the account page to try again."
                : null
            }
            onImport={(feeds, onProgress) =>
              importingPodcasts
                ? podcastImport.importer.mutateAsync({ feeds, privateFeeds, onProgress })
                : importOpmlFeeds.mutateAsync({ feeds, onProgress })
            }
          />
        </div>
      </div>
    </section>
  );
}
