"use client";

import { useMemo } from "react";
import { useViewportSidebar } from "@/hooks/useViewportSidebar";
import { Trophy, Users, UserRound, Flag, CircleDot } from "lucide-react";
import Link from "next/link";
import type { SportsEntity, SportsFeedDefinition, SportsSelection } from "@/lib/sportsFeedClient";

import { displaySportsEntityName } from "@/lib/sportsDisplayNames";
import { useSportsDisplayLocale } from "@/hooks/useSportsDisplayLocale";

const groups = [
  { title: "Sports", kinds: ["sport"], icon: CircleDot },
  { title: "Leagues and Competitions", kinds: ["competition"], icon: Trophy },
  { title: "Classes and Medley Indices", kinds: ["classification"], icon: CircleDot },
  { title: "Teams", kinds: ["team", "national-side", "ncaa-team"], icon: Users },
  { title: "Athletes and Players", kinds: ["athlete"], icon: UserRound },
  { title: "Drivers", kinds: ["driver"], icon: Flag },
];

export function SportsFollowingSidebar({ entities, definitions, selections, loading = false, error = false, feedID, onFeedChange }: {
  entities: readonly SportsEntity[];
  definitions: readonly SportsFeedDefinition[];
  selections: readonly SportsSelection[];
  loading?: boolean;
  error?: boolean;
  feedID: string;
  onFeedChange?: (id: string) => void;
}) {
  const locale = useSportsDisplayLocale();
  const sidebar = useViewportSidebar("[data-sports-scroll]");
  const { rows, feedByEntity } = useMemo(() => {
  const muted = new Set(selections.filter(selection => selection.action === "mute").map(selection => selection.reference));
  const followed = new Set(selections.filter(selection => selection.action === "follow" && !muted.has(selection.reference)).map(selection => selection.reference));
  const feedByEntity = new Map(definitions.filter(feed => feed.kind !== "global" && feed.entityIDs.length === 1).map(feed => [feed.entityIDs[0], feed]));
  const rows = entities.filter(entity => entity.active && followed.has(entity.id) && feedByEntity.has(entity.id)).sort((a, b) => displaySportsEntityName(a, locale).localeCompare(displaySportsEntityName(b, locale)));
    return { rows, feedByEntity };
  }, [selections, definitions, entities, locale]);
  const sections = [...groups, { title: "Other Interests", kinds: [...new Set(rows.filter(entity => !groups.some(group => group.kinds.includes(entity.kind))).map(entity => entity.kind))], icon: Trophy }];

  return <aside ref={sidebar} aria-labelledby="sports-following-heading" className="relative z-10 hidden self-start rounded-2xl border border-border/70 bg-background/70 p-4 backdrop-blur-md xl:sticky xl:top-4 xl:block xl:max-h-[calc(100svh-var(--environment-banner-height,0px)-3rem)] xl:overflow-y-auto xl:overscroll-contain dark:border-border/55">
    <h2 id="sports-following-heading" className="text-lg font-semibold">Following in Sports</h2>
    <Link href="/read?feed=sports" aria-current={feedID === "sports" ? "page" : undefined}
      onClick={event => {
        if (!onFeedChange || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        onFeedChange("sports");
      }}
      className="mt-3 flex min-h-11 w-full items-center gap-2 rounded-md border border-input px-3 py-2 text-sm font-medium hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring aria-[current=page]:bg-accent aria-[current=page]:text-accent-foreground">
      <Trophy aria-hidden="true" className="size-4 shrink-0" />All Sports
    </Link>
    {loading ? <p role="status" className="mt-3 text-sm text-muted-foreground">Loading Your Sports Interests…</p> : null}
    {error ? <p role="status" className="mt-3 text-sm text-muted-foreground">Your sports interests could not load. Try Refresh.</p> : null}
    {!loading && !error && rows.length === 0 ? <p className="mt-3 text-sm text-muted-foreground">Follow sports, leagues, teams, or people in Customize to see them here.</p> : null}
    {sections.map(({ title, kinds, icon: Icon }) => {
      const section = rows.filter(entity => kinds.includes(entity.kind));
      if (!section.length) return null;
      return <section key={title} className="mt-4">
        <h3 className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">{title}</h3>
        <ul className="space-y-1">
          {section.map(entity => {
            const feed = feedByEntity.get(entity.id)!;
            const href = `/read?${new URLSearchParams({ feed: "sports", sportsFeed: feed.id })}`;
            return <li key={entity.id}><a href={href} aria-current={feed.id === feedID ? "page" : undefined} onClick={event => {
              if (!onFeedChange || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
              event.preventDefault();
              onFeedChange(feed.id);
            }} className="flex min-h-11 min-w-0 items-center gap-2 rounded-md px-2 py-2 text-sm hover:bg-muted focus-visible:outline focus-visible:outline-2 focus-visible:outline-ring aria-[current=page]:bg-accent aria-[current=page]:text-accent-foreground">
              <Icon aria-hidden="true" className="size-4 shrink-0" /><span className="min-w-0 break-words">{displaySportsEntityName(entity, locale)}</span>
            </a></li>;
          })}
        </ul>
      </section>;
    })}
  </aside>;
}
