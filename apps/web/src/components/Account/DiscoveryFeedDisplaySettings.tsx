"use client";

import { Switch } from "@/components/ui/switch";
import type { FeedDisplayPreferences } from "@/lib/feedPreferences";

export function DiscoveryFeedDisplaySettings({
  preferences,
  disabled,
  onVisibilityChange,
}: {
  preferences: Pick<FeedDisplayPreferences, "showWire" | "showCircle">;
  disabled: boolean;
  onVisibilityChange: (feed: "wire" | "circle", visible: boolean) => void;
}) {
  return (["wire", "circle"] as const).map((feed) => {
    const label = feed === "wire" ? "The Wire" : "Your Circle";
    return (
      <div
        key={feed}
        className="grid min-h-12 grid-cols-[minmax(0,1fr)_5.5rem_5.5rem] items-center py-2 text-sm"
      >
        <span>{label}</span>
        <Switch
          className="justify-self-center"
          checked={feed === "wire" ? preferences.showWire : preferences.showCircle}
          disabled={disabled}
          onCheckedChange={(visible) => onVisibilityChange(feed, visible)}
          aria-label={`Show ${label}`}
        />
        <span
          className="justify-self-center text-muted-foreground"
          aria-label="Unread Count Not Available"
        >
          —
        </span>
      </div>
    );
  });
}
