"use client";

import { useRef, useState, useCallback } from "react";
import { useSpringStyle } from "@/hooks/useSpringStyle";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { sportsEventResultLabel, sportsEventStartLabel } from "@/lib/sportsEventPresentation";
import type { SportsEvent } from "@/lib/sportsFeedClient";

const fullStyle = { gridTemplateRows: "var(--sports-full-row,1fr)", opacity: "var(--sports-full-opacity,1)" };
const compactStyle = { gridTemplateRows: "var(--sports-compact-row,0fr)", opacity: "var(--sports-compact-opacity,0)" };
const previewStyles = (value: number) => ({ transform: `translateY(${(1 - value) * -6}px) scale(${0.96 + value * 0.04})`, opacity: String(Math.max(0, Math.min(1, value))) });

/** A compact schedule card expands in a portal without changing the sticky rail. */
export function SportsScheduleCard({ event, compact, hidden, highlight, contextLabel }: { event: SportsEvent; compact: boolean; hidden: boolean; highlight?: string; contextLabel: string }) {
  const [previewOpen, setPreviewOpen] = useState(false);
  const previewActions = useRef<{ unmount: () => void; close: () => void }>(null);
  const pendingPreviewExit = useRef(false);
  const previewRest = useCallback(() => {
    if (!previewOpen && pendingPreviewExit.current) { pendingPreviewExit.current = false; previewActions.current?.unmount(); }
  }, [previewOpen]);
  const previewSpring = useSpringStyle(compact && previewOpen ? 1 : 0, previewStyles, { onRest: previewRest });
  const resultLabel = sportsEventResultLabel(event);
  const startLabel = sportsEventStartLabel(event);
  const compactScore = !hidden && ["finished", "in-progress"].includes(event.status) && (event.homeScore != null || event.awayScore != null) ? `${event.homeScore ?? "—"} – ${event.awayScore ?? "—"}` : undefined;
  const scoreDescription = compactScore ? `${event.status === "finished" ? "Final" : "Current"} Score: ${compactScore}` : undefined;
  const visibleHighlight = hidden ? undefined : highlight;
  const matchupLabel = event.homeName && event.awayName ? `${event.homeAbbreviation?.trim() || event.homeName} vs ${event.awayAbbreviation?.trim() || event.awayName}` : event.title;
  const compactLabel = compactScore ? `${matchupLabel} · ${compactScore}` : matchupLabel;
  return <Tooltip disabled={!compact} open={compact && previewOpen} actionsRef={previewActions} onOpenChange={(open, details) => { pendingPreviewExit.current = !open; if (!open) details.preventUnmountOnClose(); setPreviewOpen(open); }}><TooltipTrigger closeOnClick={false} aria-label={compact ? [event.title, scoreDescription].filter(Boolean).join(" · ") : undefined} onFocus={() => setPreviewOpen(true)} onBlur={() => previewActions.current?.close()} tabIndex={compact ? 0 : undefined} render={<article className={`w-max min-w-52 max-w-[min(24rem,calc(100vw-2rem))] shrink-0 whitespace-normal rounded-md border px-2 text-sm [overflow-wrap:anywhere] ${visibleHighlight === "In Progress" ? "border-red-500 bg-red-500/10" : visibleHighlight ? "border-red-500/40 bg-red-500/5" : ""}`} style={{ paddingBlock: "var(--sports-card-padding,8px)" }} />} >
      {visibleHighlight ? <div className="grid" style={fullStyle} aria-hidden={compact}><p className="min-h-0 overflow-hidden text-xs font-medium text-red-700 dark:text-red-300">{visibleHighlight}</p></div> : null}
      {contextLabel ? <p className="mb-1 min-w-0 text-xs text-muted-foreground">{contextLabel}</p> : null}
      <p className="grid min-w-0 font-medium" title={event.title} aria-label={compact ? [event.title, scoreDescription].filter(Boolean).join(" · ") : undefined}>
        {compactLabel === event.title ? event.title : <>
          <span data-schedule-label="full" aria-hidden={compact} className="pointer-events-none col-start-1 row-start-1 grid" style={fullStyle}><span className="min-h-0 overflow-hidden">{event.title}</span></span>
          <span data-schedule-label="compact" aria-hidden={!compact} className="pointer-events-none col-start-1 row-start-1 grid" style={compactStyle}><span className="min-h-0 overflow-hidden">{compactLabel}</span></span>
        </>}
      </p>
      <time dateTime={event.startsAt} className="block min-w-0 text-muted-foreground">{startLabel}</time>
      {!hidden && resultLabel ? <div className="grid" style={fullStyle} aria-hidden={compact}><p className="min-h-0 overflow-hidden">{resultLabel}</p></div> : null}
    </TooltipTrigger>
    <TooltipContent ref={previewSpring} aria-hidden={!previewOpen} inert={!previewOpen} role="tooltip" side="bottom" align="start" className="block max-w-[min(24rem,calc(100vw-2rem))] border bg-background p-3 text-sm text-foreground shadow-lg whitespace-normal [overflow-wrap:anywhere] data-open:animate-none data-closed:animate-none motion-reduce:animate-none" arrowClassName="bg-background fill-background">
      {visibleHighlight ? <p className="mb-1 text-xs font-medium text-red-700 dark:text-red-300">{visibleHighlight}</p> : null}
      {contextLabel ? <p className="mb-1 text-xs text-muted-foreground">{contextLabel}</p> : null}
      <p className="font-medium">{event.title}</p>
      <time dateTime={event.startsAt} className="block text-muted-foreground">{startLabel}</time>
      {!hidden && resultLabel ? <p>{resultLabel}</p> : null}
    </TooltipContent>
    </Tooltip>;
}
