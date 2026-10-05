"use client";

import { Switch } from "@/components/ui/switch";
import type { FeedDisplayPreferences } from "@/lib/feedPreferences";

const feeds = [
  { id: "wire", label: "The Wire", preference: "showWire" },
  { id: "circle", label: "Your Circle", preference: "showCircle" },
  { id: "finance", label: "Finance", preference: "showFinance" },
  { id: "sports", label: "Sports", preference: "showSports" },
] as const;

type DiscoveryFeedDisplaySettingsProps = {
  preferences: Pick<FeedDisplayPreferences, "showWire" | "showCircle" | "showFinance" | "showSports">;
  isPending: boolean;
  onVisibilityChange: (feed: "wire" | "circle" | "finance" | "sports", visible: boolean) => void;
};

export function DiscoveryFeedDisplaySettings({
  preferences,
  isPending,
  onVisibilityChange,
}: DiscoveryFeedDisplaySettingsProps) {
  return feeds.map(({ id, label, preference }) => (
    <div
      key={id}
      className="grid min-h-12 grid-cols-[minmax(0,1fr)_5.5rem_5.5rem] items-center py-2 text-sm"
    >
      <span>{label}</span>
      <Switch
        className="justify-self-center"
        checked={preferences[preference]}
        disabled={isPending}
        onCheckedChange={visible => onVisibilityChange(id, visible)}
        aria-label={`Show ${label}`}
      />
      <span
        className="justify-self-center text-muted-foreground"
        aria-label="Unread Count Not Available"
      >
        —
      </span>
    </div>
  ));
}
