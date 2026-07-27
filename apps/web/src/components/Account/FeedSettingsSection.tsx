"use client";

import { Switch } from "@/components/ui/switch";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import {
  TOP_LEVEL_FEEDS,
  type TopLevelFeed,
} from "@/lib/feedPreferences";

const FEED_LABELS: Record<TopLevelFeed, string> = {
  readLater: "Read Later",
  archive: "Archive",
  subscribed: "Subscribed",
  following: "Following",
};

export function FeedSettingsSection() {
  const {
    preferences,
    setFeedVisible,
    setShowTopLevelFeedUnreadCounts,
    isPending,
    error,
  } = useFeedDisplayPreferences();

  return (
    <section
      id="settings"
      className="flex scroll-mt-16 flex-col border-t p-4 md:p-6"
      aria-labelledby="settings-heading"
    >
      <div className="mx-auto flex w-full max-w-2xl flex-col gap-6">
        <header>
          <h1
            id="settings-heading"
            className="text-xl font-black tracking-tight"
          >
            Settings
          </h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Choose which top-level feeds appear in the reader.
          </p>
        </header>
        <section className="rounded-2xl border bg-card p-4 shadow-[var(--soft-elevation)]">
          <h2 className="text-sm font-bold">Visible Feeds</h2>
          <div className="mt-3 divide-y">
            {TOP_LEVEL_FEEDS.map((feed) => {
              const checked = preferences.visibleFeeds.includes(feed);
              const finalVisible =
                checked && preferences.visibleFeeds.length === 1;
              return (
                <label
                  key={feed}
                  className="flex min-h-12 items-center justify-between gap-4 py-2 text-sm"
                >
                  <span>{FEED_LABELS[feed]}</span>
                  <Switch
                    checked={checked}
                    disabled={isPending || finalVisible}
                    onCheckedChange={(value) =>
                      setFeedVisible(feed, value)
                    }
                    aria-label={`Show ${FEED_LABELS[feed]}`}
                  />
                </label>
              );
            })}
          </div>
        </section>
        <section className="rounded-2xl border bg-card p-4 shadow-[var(--soft-elevation)]">
          <label className="flex min-h-12 items-center justify-between gap-4 text-sm">
            <span>
              <span className="block font-bold">Show Feed Unread Counts</span>
              <span className="block text-xs text-muted-foreground">
                Controls badges on the four top-level feeds.
              </span>
            </span>
            <Switch
              checked={preferences.showTopLevelFeedUnreadCounts}
              disabled={isPending}
              onCheckedChange={setShowTopLevelFeedUnreadCounts}
              aria-label="Show Feed Unread Counts"
            />
          </label>
        </section>
        {error ? (
          <p role="alert" className="text-sm text-destructive">
            {error instanceof Error
              ? error.message
              : "Could not save settings."}
          </p>
        ) : null}
      </div>
    </section>
  );
}
