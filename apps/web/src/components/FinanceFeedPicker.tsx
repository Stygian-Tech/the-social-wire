"use client";

import { createElement } from "react";
import { Select } from "@base-ui/react/select";
import {
  Building2,
  Car,
  ChartNoAxesCombined,
  Check,
  ChevronDown,
  CircuitBoard,
  Clapperboard,
  Code2,
  Cpu,
  CreditCard,
  Dna,
  Factory,
  Fuel,
  HeartPulse,
  Landmark,
  Monitor,
  Package,
  Pill,
  Pickaxe,
  Plane,
  RadioTower,
  ShieldCheck,
  ShoppingBag,
  Stethoscope,
  Store,
  Truck,
  UsersRound,
  Utensils,
  Zap,
  type LucideIcon,
} from "lucide-react";
import type { FinanceFeedDefinition } from "@/lib/financeFeedClient";

const industryIcons: Record<string, LucideIcon> = {
  technology: Cpu,
  healthcare: HeartPulse,
  financials: Landmark,
  energy: Fuel,
  materials: Pickaxe,
  industrials: Factory,
  consumer: ShoppingBag,
  communications: RadioTower,
  utilities: Zap,
  "real-estate": Building2,
  pharma: Pill,
  biotech: Dna,
  semiconductors: CircuitBoard,
  software: Code2,
  banks: Landmark,
  insurance: ShieldCheck,
  "oil-gas": Fuel,
  "aerospace-defense": Plane,
  autos: Car,
  retail: Store,
  telecom: RadioTower,
  media: Clapperboard,
  hardware: Monitor,
  "consumer-products": Package,
  restaurants: Utensils,
  "medical-devices": Stethoscope,
  payments: CreditCard,
  "asset-management": Landmark,
  manufacturing: Factory,
  transportation: Truck,
  mining: Pickaxe,
};
function feedIcon(feed: FinanceFeedDefinition | undefined) {
  const Icon =
    feed?.kind === "industry"
      ? (industryIcons[feed.id.slice("industry:".length)] ?? Factory)
      : feed?.kind === "group"
        ? UsersRound
        : feed?.kind === "instrument"
          ? Building2
          : ChartNoAxesCombined;
  return createElement(Icon, {
    "aria-hidden": true,
    className: "size-4 shrink-0",
  });
}
const groups = [
  ["all", "All"],
  ["industry", "Industries"],
  ["group", "Groups"],
  ["instrument", "Companies"],
] as const;

type Props = {
  definitions: FinanceFeedDefinition[];
  feedID: string;
  companySearch: string;
  onFeedChange?: (id: string) => void;
};
export function FinanceFeedPicker({
  definitions,
  feedID,
  companySearch,
  onFeedChange,
}: Props) {
  const selected = definitions.find((feed) => feed.id === feedID);
  const fallback = !definitions.length ? "Finance" : "Unavailable Feed";
  const items = Object.fromEntries(
    definitions.map((feed) => [feed.id, feed.title]),
  );
  if (!selected) items[feedID] = fallback;
  const query = companySearch.trim().toLocaleLowerCase();
  return (
    <Select.Root
      value={feedID}
      items={items}
      onValueChange={(value) => {
        if (value) onFeedChange?.(value);
      }}
    >
      <Select.Trigger
        aria-label="Finance Feed"
        className="flex w-full min-w-0 items-center gap-2 rounded-md border border-input bg-background px-3 py-3 text-left text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        {feedIcon(selected)}
        <Select.Value className="min-w-0 flex-1 truncate" />
        <Select.Icon>
          <ChevronDown aria-hidden="true" className="size-4 shrink-0" />
        </Select.Icon>
      </Select.Trigger>
      <Select.Portal>
        <Select.Positioner
          align="start"
          side="bottom"
          sideOffset={6}
          alignItemWithTrigger={false}
          className="z-50 max-w-[calc(100vw-2rem)]"
        >
          <Select.Popup className="w-(--anchor-width) min-w-[min(20rem,calc(100vw-2rem))] max-w-[calc(100vw-2rem)] overflow-hidden rounded-lg border bg-popover text-popover-foreground shadow-md outline-none">
            <Select.List className="max-h-[min(24rem,var(--available-height))] overflow-y-auto overscroll-contain p-1">
              {!selected ? (
                <Select.Item
                  value={feedID}
                  label={fallback}
                  className="flex min-h-11 items-center gap-2 rounded-md px-2 py-2 text-sm data-highlighted:bg-accent data-highlighted:text-accent-foreground"
                >
                  {feedIcon(selected)}
                  <Select.ItemText className="min-w-0 flex-1 break-words leading-5">
                    {fallback}
                  </Select.ItemText>
                  <Select.ItemIndicator>
                    <Check aria-hidden="true" className="size-4" />
                  </Select.ItemIndicator>
                </Select.Item>
              ) : null}
              {groups.map(([kind, label]) => {
                const feeds = definitions.filter(
                  (feed) =>
                    feed.kind === kind &&
                    (kind !== "instrument" ||
                      feed.id === feedID ||
                      feed.title.toLocaleLowerCase().includes(query)),
                );
                if (!feeds.length) return null;
                return (
                  <Select.Group key={kind} aria-label={label}>
                    <Select.GroupLabel className="px-2 pb-1 pt-2 text-xs font-semibold text-muted-foreground">
                      {label}
                    </Select.GroupLabel>
                    {feeds.map((feed) => {
                      return (
                        <Select.Item
                          key={feed.id}
                          value={feed.id}
                          label={feed.title}
                          className="flex min-h-11 items-center gap-2 rounded-md px-2 py-2 text-sm data-highlighted:bg-accent data-highlighted:text-accent-foreground"
                        >
                          {feedIcon(feed)}
                          <Select.ItemText className="min-w-0 flex-1 break-words leading-5">
                            {feed.title}
                          </Select.ItemText>
                          <Select.ItemIndicator>
                            <Check
                              aria-hidden="true"
                              className="size-4 shrink-0"
                            />
                          </Select.ItemIndicator>
                        </Select.Item>
                      );
                    })}
                  </Select.Group>
                );
              })}
            </Select.List>
          </Select.Popup>
        </Select.Positioner>
      </Select.Portal>
    </Select.Root>
  );
}
