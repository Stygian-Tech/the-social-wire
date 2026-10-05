import type { SportsFeedDefinition } from "@/lib/sportsFeedClient";

import { displaySportsGroupPath, sportsFeedSearchText } from "@/lib/sportsDisplayNames";

const kinds = [["global", "All"], ["sport", "Sports"], ["competition", "Competitions"], ["classification", "Classes and Medley Indices"], ["team", "Teams"], ["national-side", "National Sides"], ["ncaa-team", "NCAA Teams"], ["organization", "Programs"], ["athlete", "Athletes"], ["driver", "Drivers"]] as const;
export type SportsFeedPickerGroup = { id: string; label: string; feeds: SportsFeedDefinition[] };
export type SportsPickerFeedDefinition = SportsFeedDefinition & { searchAliases?: readonly string[] };

/** Catalog paths describe sport, division and conference; they are presentation metadata, never identity. */
export function sportsFeedPickerGroups(definitions: readonly SportsPickerFeedDefinition[], selectedID: string, search: string, locale?: string): SportsFeedPickerGroup[] {
  const query = search.trim().toLocaleLowerCase();
  const groups = new Map<string, SportsFeedPickerGroup>();
  const labels = new Map<string, string>(kinds);
  for (const feed of definitions) {
    const label = labels.get(feed.kind);
    if (!label) continue;
    const path = (feed.groupPath ?? []).filter(part => part.trim().length > 0);
    const searchText = sportsFeedSearchText(feed, locale);
    const personVisible = !["athlete", "driver"].includes(feed.kind) || query.length >= 2;
    if (feed.kind !== "global" && feed.id !== selectedID && (!personVisible || !searchText.includes(query))) continue;
    const id = JSON.stringify([feed.kind, ...path]);
    let group = groups.get(id);
    if (!group) {
      group = { id, label: displaySportsGroupPath(path[0] === label ? path : [label, ...path], locale).join(" › "), feeds: [] };
      groups.set(id, group);
    }
    group.feeds.push(feed);
  }
  const order = new Map<string, number>(kinds.map(([kind], index) => [kind, index]));
  return [...groups.values()].sort((a, b) => (order.get(a.feeds[0]!.kind)! - order.get(b.feeds[0]!.kind)!) || a.label.localeCompare(b.label));
}
