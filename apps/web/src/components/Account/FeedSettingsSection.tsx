"use client";

import { Switch } from "@/components/ui/switch";
import { AppearanceSettingsSection } from "@/components/Account/AppearanceSettingsSection";
import { useFeedDisplayPreferences } from "@/hooks/useFeedDisplayPreferences";
import {
  TOP_LEVEL_FEEDS,
  TOP_LEVEL_FEED_LABELS,
} from "@/lib/feedPreferences";

export function FeedSettingsSection() {
  const {
    preferences,
    setFeedVisible,
    setFeedUnreadCountVisible,
    setRssArticleOpenInReader,
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
          <h2
            id="settings-heading"
            className="text-xl font-black tracking-tight"
          >
            Settings
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Customize the app&apos;s appearance and choose which top-level feeds appear.
          </p>
        </header>
        <AppearanceSettingsSection />
        <section className="rounded-2xl border bg-card p-4 shadow-[var(--soft-elevation)]">
          <h2 className="text-sm font-bold">RSS Articles</h2>
          <div className="mt-3 flex min-h-12 items-center justify-between gap-4">
            <div className="min-w-0">
              <p className="text-sm font-medium text-foreground">
                Open in Reader
              </p>
              <p className="mt-0.5 text-xs leading-5 text-muted-foreground">
                Render feed content inside The Social Wire using your appearance
                settings. Turn this off to open the original publisher page.
              </p>
            </div>
            <Switch
              className="shrink-0"
              checked={preferences.rssArticleOpenMode === "reader"}
              disabled={isPending}
              onCheckedChange={setRssArticleOpenInReader}
              aria-label="Open RSS Articles in Reader"
            />
          </div>
        </section>
        <section className="rounded-2xl border bg-card p-4 shadow-[var(--soft-elevation)]">
          <h2 className="text-sm font-bold">Feed Display</h2>
          <div className="mt-3 grid grid-cols-[minmax(0,1fr)_5.5rem_5.5rem] items-center border-b pb-2 text-xs font-semibold text-muted-foreground">
            <span>Feed</span>
            <span className="justify-self-center">Show Feed</span>
            <span className="justify-self-center">Show Count</span>
          </div>
          <div className="mt-3 divide-y">
            {TOP_LEVEL_FEEDS.map((feed) => {
              const feedVisible = preferences.visibleFeeds.includes(feed);
              const countVisible =
                preferences.feedsWithUnreadCounts.includes(feed);
              const finalVisible =
                feedVisible && preferences.visibleFeeds.length === 1;
              return (
                <div
                  key={feed}
                  className="grid min-h-12 grid-cols-[minmax(0,1fr)_5.5rem_5.5rem] items-center py-2 text-sm"
                >
                  <span>{TOP_LEVEL_FEED_LABELS[feed]}</span>
                  <Switch
                    className="justify-self-center"
                    checked={feedVisible}
                    disabled={isPending || finalVisible}
                    onCheckedChange={(value) =>
                      setFeedVisible(feed, value)
                    }
                    aria-label={`Show ${TOP_LEVEL_FEED_LABELS[feed]}`}
                  />
                  <Switch
                    className="justify-self-center"
                    checked={countVisible}
                    disabled={isPending || !feedVisible}
                    onCheckedChange={(value) =>
                      setFeedUnreadCountVisible(feed, value)
                    }
                    aria-label={`Show ${TOP_LEVEL_FEED_LABELS[feed]} Count`}
                  />
                </div>
              );
            })}
          </div>
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
