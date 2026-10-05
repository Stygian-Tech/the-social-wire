"use client";
import { useEffect, useState } from "react";
import { useAuth } from "@/hooks/useAuth";
import {
  podcastRequest,
  writePodcastSubscription,
  type PodcastShow,
} from "@/lib/podcasts/client";
type BridgeJob = { id: string; status: string; error?: string };
export function PodcastBridgeStatus({
  show,
  subscribed,
}: {
  show: PodcastShow;
  subscribed: boolean;
}) {
  const { session, getOAuthSession } = useAuth();
  const [job, setJob] = useState<BridgeJob | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    const oauth = getOAuthSession();
    if (!oauth || !session || show.sourceKind !== "rss" || !subscribed) return;
    let cancelled = false;
    let linked = false;
    const refresh = async () => {
      try {
        const result = await podcastRequest<BridgeJob>(
          oauth,
          `jobs?showId=${encodeURIComponent(show.id)}`,
        );
        if (cancelled) return;
        setJob(result);
        if (result.status === "complete" && !linked) {
          const catalog = await podcastRequest<{ shows: PodcastShow[] }>(
            oauth,
            "shows",
          );
          const mirrored = catalog.shows.find((item) => item.id === show.id);
          if (mirrored?.sourceUri && !cancelled) {
            await writePodcastSubscription(oauth, session.did, mirrored);
            linked = true;
          }
        }
      } catch {
        /* The bridge may not be enqueued until subscription hydration finishes. */
      }
    };
    void refresh();
    const timer = setInterval(() => void refresh(), 10000);
    return () => {
      cancelled = true;
      clearInterval(timer);
    };
  }, [show.id, show.sourceKind, subscribed, getOAuthSession, session]);
  if (show.sourceKind !== "rss" || !subscribed) return null;
  return (
    <div className="mt-2 text-xs text-muted-foreground">
      <p role="status">AT Protocol Bridge: {job?.status ?? "Pending"}</p>
      {job?.error ? <p className="text-destructive">{job.error}</p> : null}
      {job?.status === "failed" ? (
        <button
          className="min-h-9 underline"
          onClick={() => {
            const oauth = getOAuthSession();
            if (oauth)
              void podcastRequest(oauth, "jobs", "POST", { jobId: job.id })
                .then(() => setJob({ ...job, status: "queued" }))
                .catch((reason) => setError(String(reason)));
          }}
        >
          Retry Bridge
        </button>
      ) : null}
      {error ? (
        <p role="alert" className="text-destructive">
          {error}
        </p>
      ) : null}
    </div>
  );
}
