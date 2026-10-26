"use client";

import { CachedImage } from "@/components/shared/CachedImage";

import { useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import type { AppBskyEmbedImages } from "@atproto/api";
import { socialHttpsUrl } from "./socialUrls";
import { SocialAltTextBadge } from "./SocialAltTextBadge";
import { SocialImageDialog } from "./SocialImageDialog";

export function SocialImageGallery({ images }: { images: readonly AppBskyEmbedImages.ViewImage[] }) {
  const [active, setActive] = useState(0);
  const carousel = useRef<HTMLDivElement>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const drag = useRef<{ id: number; x: number; y: number; horizontal: boolean; vertical: boolean } | null>(null);
  const suppressClick = useRef(false);
  const clearClick = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(clearClick.current), []);
  const safeImages = images.filter(image => socialHttpsUrl(image.thumb));
  useEffect(() => {
    const element = carousel.current;
    if (!element || safeImages.length < 2) return;
    let accumulated = 0;
    let lastWheel = 0;
    let navigated = false;
    const wheel = (event: WheelEvent) => {
      // Preserve vertical feed scrolling and trackpad pinch-to-zoom.
      if (event.ctrlKey || Math.abs(event.deltaX) <= Math.abs(event.deltaY) * 1.5) return;
      const now = Date.now();
      if (now - lastWheel > 180) { accumulated = 0; navigated = false; }
      lastWheel = now;
      event.preventDefault();
      event.stopPropagation();
      if (navigated) return;
      const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? element.clientWidth : 1;
      accumulated += event.deltaX * unit;
      if (Math.abs(accumulated) < 40) return;
      navigated = true;
      const direction = accumulated > 0 ? 1 : -1;
      setActive(previous => Math.max(0, Math.min(Math.min(previous, safeImages.length - 1) + direction, safeImages.length - 1)));
    };
    element.addEventListener("wheel", wheel, { passive: false });
    return () => element.removeEventListener("wheel", wheel);
  }, [safeImages.length]);
  if (!safeImages.length) return null;
  const index = Math.min(active, safeImages.length - 1);
  const image = safeImages[index];
  // Keep the feed row fixed while paging or loading differently sized photos.
  const ratio = safeImages[0].aspectRatio;
  const aspectRatio = ratio && Number.isFinite(ratio.width) && Number.isFinite(ratio.height) && ratio.width > 0 && ratio.height > 0
    ? `${ratio.width} / ${ratio.height}` : "1 / 1";
  const multiple = safeImages.length > 1;
  const navigate = (next: number) => setActive(Math.max(0, Math.min(next, safeImages.length - 1)));
  const select = (next: number) => { navigate(next); setSelected(next); };
  const selectedIndex = selected === null ? null : Math.min(selected, safeImages.length - 1);
  return <>
    <div ref={carousel} role="group" aria-roledescription={multiple ? "carousel" : undefined} aria-label="Post Images" className="flex min-w-0 flex-col gap-2"
      style={{ touchAction: "pan-y" }}
      onClickCapture={event => { if (suppressClick.current) { event.preventDefault(); event.stopPropagation(); suppressClick.current = false; } }}
      onPointerDown={event => {
        const target = event.target as Element;
        if (!multiple || event.button !== 0 || (target.closest("button, a, input, textarea, select, [role='button']") && !target.closest("[data-gallery-image]"))) return;
        if (event.isPrimary === false || drag.current) { drag.current = null; return; }
        suppressClick.current = false;
        drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY, horizontal: false, vertical: false };
      }}
      onPointerMove={event => {
        const gesture = drag.current;
        if (!gesture || gesture.id !== event.pointerId || gesture.vertical) return;
        const dx = Math.abs(event.clientX - gesture.x), dy = Math.abs(event.clientY - gesture.y);
        if (!gesture.horizontal && dy > 10 && dy > dx) { gesture.vertical = true; return; }
        if (!gesture.horizontal && dx > 12 && dx > dy * 1.5) {
          gesture.horizontal = true;
          event.currentTarget.setPointerCapture?.(event.pointerId);
        }
        if (gesture.horizontal) event.preventDefault();
      }}
      onPointerUp={event => {
        const gesture = drag.current;
        drag.current = null;
        if (!gesture || gesture.id !== event.pointerId || !gesture.horizontal) return;
        if (event.currentTarget.hasPointerCapture?.(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
        suppressClick.current = true;
        clearTimeout(clearClick.current);
        clearClick.current = setTimeout(() => { suppressClick.current = false; }, 300);
        const dx = event.clientX - gesture.x;
        if (Math.abs(dx) >= 40) navigate(index + (dx < 0 ? 1 : -1));
      }}
      onPointerCancel={() => { drag.current = null; }}
      onKeyDown={event => {
        if (!multiple || !event.currentTarget.contains(event.target as Node)) return;
        const next = event.key === "ArrowRight" ? index + 1 : event.key === "ArrowLeft" ? index - 1 : event.key === "Home" ? 0 : event.key === "End" ? safeImages.length - 1 : undefined;
        if (next !== undefined) { event.preventDefault(); event.stopPropagation(); navigate(next); }
      }}>
      <div className="relative min-w-0">
        <button type="button" data-gallery-image aria-label={`Open Image ${index + 1}${image.alt ? `: ${image.alt}` : ""}`}
          style={{ aspectRatio }}
          className="block w-full min-w-0 overflow-hidden rounded-xl outline-offset-4 focus-visible:outline-2 focus-visible:outline-ring"
          onClick={event => { event.stopPropagation(); setSelected(index); }}>
          <CachedImage src={socialHttpsUrl(image.thumb)} alt={image.alt} width={image.aspectRatio?.width ?? 1200} height={image.aspectRatio?.height ?? 800}
            loading="lazy" draggable={false} className="block h-full w-full object-contain" />
        </button>
        <SocialAltTextBadge key={`${image.thumb}:${index}`} alt={image.alt} label={`View Image ${index + 1} Alt Text`} />
      </div>
      {multiple ? <div className="flex items-center justify-between gap-2">
        <button type="button" aria-label="Previous Photo" disabled={index === 0} className="rounded-md p-1 hover:bg-muted disabled:opacity-40" onClick={event => { event.stopPropagation(); navigate(index - 1); }}><ChevronLeft aria-hidden="true" className="size-5" /></button>
        <div className="flex min-w-0 items-center gap-2"><span className="text-xs text-muted-foreground" aria-live="polite">{index + 1} / {safeImages.length}</span>
          <div className="flex flex-wrap gap-1" aria-label="Choose Photo">{safeImages.map((item, position) => <button key={`${item.thumb}:${position}`} type="button" aria-label={`Show Photo ${position + 1}`} aria-pressed={position === index} className="flex size-6 items-center justify-center rounded-full focus-visible:outline-2 focus-visible:outline-ring" onClick={event => { event.stopPropagation(); navigate(position); }}><span aria-hidden="true" className={`size-2 rounded-full ${position === index ? "bg-foreground" : "bg-muted-foreground/40"}`} /></button>)}</div>
        </div>
        <button type="button" aria-label="Next Photo" disabled={index === safeImages.length - 1} className="rounded-md p-1 hover:bg-muted disabled:opacity-40" onClick={event => { event.stopPropagation(); navigate(index + 1); }}><ChevronRight aria-hidden="true" className="size-5" /></button>
      </div> : null}
    </div>
    {selectedIndex !== null ? <SocialImageDialog image={safeImages[selectedIndex]} index={selectedIndex} total={safeImages.length}
      onClose={() => setSelected(null)} onPrevious={selectedIndex > 0 ? () => select(selectedIndex - 1) : undefined} onNext={selectedIndex < safeImages.length - 1 ? () => select(selectedIndex + 1) : undefined} /> : null}
  </>;
}
