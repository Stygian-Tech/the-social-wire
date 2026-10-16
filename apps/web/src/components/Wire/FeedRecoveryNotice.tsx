import { Clock3, Network } from "lucide-react";

import type { WireEditionPage } from "@/lib/wireEditionClient";

const updatedAtFormatter = new Intl.DateTimeFormat("en", {
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
  timeZone: "UTC",
  timeZoneName: "short",
});

export function FeedRecoveryNotice({
  edition,
  circle = false,
}: {
  edition: Pick<WireEditionPage, "source" | "degraded" | "generatedAt">;
  circle?: boolean;
}) {
  const staleSource = edition.source === "stale_generation";
  if (!staleSource && !edition.degraded) return null;
  // Circle's stale source describes its network graph. Its generatedAt is the
  // candidate fetch time, so it cannot date the graph's last successful refresh.
  const staleEdition = staleSource && !circle;

  const generatedAt = new Date(edition.generatedAt);
  const validDate = Number.isFinite(generatedAt.getTime());
  const Icon = staleEdition ? Clock3 : Network;

  return (
    <div className="px-4 pt-4 sm:px-5 sm:pt-5">
      <div
        role="status"
        className="flex min-w-0 items-start gap-3 rounded-2xl border border-amber-600/25 bg-amber-50 p-3 text-amber-950 dark:border-amber-400/20 dark:bg-amber-400/10 dark:text-amber-100 sm:p-4"
      >
        <Icon className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
        <div className="min-w-0 space-y-1 text-sm [overflow-wrap:anywhere]">
          <p className="font-semibold">
            {staleEdition ? "Updates Are Delayed" : circle ? "Limited Network Coverage" : "The Wire Is Refreshing"}
          </p>
          <p className="text-xs leading-relaxed">
            {staleEdition
              ? "Showing the last available edition while new stories catch up."
              : circle
                ? "Your Circle is refreshing. Some stories from your network may be missing for now."
                : "New stories are catching up. Coverage may be limited for now."}
          </p>
          {staleEdition && validDate ? (
            <p className="text-xs leading-relaxed">
              Last Updated{" "}
              <time dateTime={edition.generatedAt}>{updatedAtFormatter.format(generatedAt)}</time>
            </p>
          ) : null}
        </div>
      </div>
    </div>
  );
}
