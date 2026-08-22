"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import type { ReactNode } from "react";
import { useCallback, useEffect, useRef, useState } from "react";

export function WireHorizontalRail({
  id,
  title,
  eyebrow,
  onNearEnd,
  children,
}: {
  id: string;
  title: string;
  eyebrow?: string;
  onNearEnd?: () => void;
  children: ReactNode;
}) {
  const headingId = `wire-rail-${id}`;
  const railRef = useRef<HTMLDivElement>(null);
  const [canPrevious, setCanPrevious] = useState(false);
  const [canNext, setCanNext] = useState(false);
  const nearEndTriggeredRef = useRef(false);

  const updateControls = useCallback(() => {
    const rail = railRef.current;
    if (!rail) return;
    setCanPrevious(rail.scrollLeft > 1);
    setCanNext(rail.scrollLeft + rail.clientWidth < rail.scrollWidth - 1);
  }, []);

  useEffect(() => {
    const rail = railRef.current;
    if (!rail) return;
    updateControls();
    nearEndTriggeredRef.current = false;
    const handleScroll = () => {
      updateControls();
      const remaining = rail.scrollWidth - rail.clientWidth - rail.scrollLeft;
      if (
        onNearEnd &&
        !nearEndTriggeredRef.current &&
        remaining <= Math.max(120, rail.clientWidth * 0.5)
      ) {
        nearEndTriggeredRef.current = true;
        onNearEnd();
      }
    };
    rail.addEventListener("scroll", handleScroll, { passive: true });
    window.addEventListener("resize", updateControls);
    const observer =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver(updateControls);
    observer?.observe(rail);
    return () => {
      rail.removeEventListener("scroll", handleScroll);
      window.removeEventListener("resize", updateControls);
      observer?.disconnect();
    };
  }, [children, onNearEnd, updateControls]);

  const scroll = useCallback((direction: -1 | 1) => {
    const rail = railRef.current;
    if (!rail) return;
    const reduceMotion = window.matchMedia?.(
      "(prefers-reduced-motion: reduce)",
    ).matches;
    rail.scrollBy({
      left: direction * Math.max(240, rail.clientWidth * 0.85),
      behavior: reduceMotion ? "auto" : "smooth",
    });
  }, []);

  return (
    <section aria-labelledby={headingId} className="min-w-0">
      <div className="mb-3 flex items-end justify-between gap-3 pl-5 pr-4 sm:pl-6 sm:pr-5">
        <div className="min-w-0">
          {eyebrow ? (
            <p className="text-[11px] font-bold uppercase tracking-[0.14em] text-[var(--purple-foreground)]">
              {eyebrow}
            </p>
          ) : null}
          <h2
            id={headingId}
            className="truncate text-lg font-bold text-foreground"
          >
            {title}
          </h2>
        </div>
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            aria-label={`Previous ${title}`}
            disabled={!canPrevious}
            onClick={() => scroll(-1)}
            className="inline-flex size-8 items-center justify-center rounded-full border border-border/70 bg-background text-foreground shadow-sm transition-colors hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-35"
          >
            <ChevronLeft className="size-4" aria-hidden="true" />
          </button>
          <button
            type="button"
            aria-label={`Next ${title}`}
            disabled={!canNext}
            onClick={() => scroll(1)}
            className="inline-flex size-8 items-center justify-center rounded-full border border-border/70 bg-background text-foreground shadow-sm transition-colors hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-35"
          >
            <ChevronRight className="size-4" aria-hidden="true" />
          </button>
        </div>
      </div>
      <div
        ref={railRef}
        role="group"
        aria-label={`${title} carousel`}
        tabIndex={0}
        className="flex snap-x snap-mandatory scroll-pl-5 scroll-pr-4 gap-3 overflow-x-auto pb-2 pl-5 pr-4 outline-none [scrollbar-width:none] focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring sm:scroll-pl-6 sm:scroll-pr-5 sm:pl-6 sm:pr-5 [&::-webkit-scrollbar]:hidden"
      >
        {children}
      </div>
    </section>
  );
}
