"use client";

import {
  useCallback,
  useEffect,
  useId,
  useState,
  type ReactNode,
} from "react";

import { cn } from "@/lib/utils";

const DEFAULT_WIDTH_PX = 288;
const MIN_WIDTH_PX = 240;
const MAX_WIDTH_PX = 560;

function clampWidth(value: number): number {
  return Math.min(MAX_WIDTH_PX, Math.max(MIN_WIDTH_PX, value));
}

function readStoredWidth(storageKey: string): number {
  if (typeof window === "undefined") return DEFAULT_WIDTH_PX;
  try {
    const raw = localStorage.getItem(storageKey);
    const parsed = raw ? Number.parseInt(raw, 10) : NaN;
    if (!Number.isFinite(parsed)) return DEFAULT_WIDTH_PX;
    return clampWidth(parsed);
  } catch {
    return DEFAULT_WIDTH_PX;
  }
}

function useResizableListColumnWidth(storageKey: string) {
  const [widthPx, setWidthPxState] = useState(DEFAULT_WIDTH_PX);

  useEffect(() => {
    setWidthPxState(readStoredWidth(storageKey));
  }, [storageKey]);

  const setWidthPx = useCallback(
    (value: number) => {
      const clamped = clampWidth(value);
      setWidthPxState(clamped);
      try {
        localStorage.setItem(storageKey, String(clamped));
      } catch {
        /* ignore quota / private mode */
      }
    },
    [storageKey]
  );

  return { widthPx, setWidthPx };
}

type ResizableListColumnProps = {
  storageKey: string;
  className?: string;
  /** When true, hide the column on small screens (e.g. mobile detail view). */
  hiddenOnMobile?: boolean;
  children: ReactNode;
};

export function ResizableListColumn({
  storageKey,
  className,
  hiddenOnMobile = false,
  children,
}: ResizableListColumnProps) {
  const { widthPx, setWidthPx } = useResizableListColumnWidth(storageKey);
  const labelId = useId();

  const onPointerDown = useCallback(
    (event: React.PointerEvent<HTMLDivElement>) => {
      if (typeof window !== "undefined" && window.matchMedia("(max-width: 767px)").matches) {
        return;
      }
      event.preventDefault();
      const startX = event.clientX;
      const startW = widthPx;
      const target = event.currentTarget;
      target.setPointerCapture(event.pointerId);

      const onMove = (ev: PointerEvent) => {
        setWidthPx(startW + (ev.clientX - startX));
      };

      const onEnd = (ev: PointerEvent) => {
        if (target.hasPointerCapture(ev.pointerId)) {
          target.releasePointerCapture(ev.pointerId);
        }
        target.removeEventListener("pointermove", onMove);
        target.removeEventListener("pointerup", onEnd);
        target.removeEventListener("pointercancel", onEnd);
      };

      target.addEventListener("pointermove", onMove);
      target.addEventListener("pointerup", onEnd);
      target.addEventListener("pointercancel", onEnd);
    },
    [setWidthPx, widthPx]
  );

  const onKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      const step = event.shiftKey ? 24 : 8;
      if (event.key === "ArrowRight") {
        event.preventDefault();
        setWidthPx(widthPx + step);
      } else if (event.key === "ArrowLeft") {
        event.preventDefault();
        setWidthPx(widthPx - step);
      }
    },
    [setWidthPx, widthPx]
  );

  return (
    <aside
      className={cn(
        "relative flex min-h-0 min-w-0 flex-col overflow-hidden border-r bg-muted/20",
        "w-full flex-1 md:h-full md:shrink-0 md:flex-none md:w-[var(--list-column-width)]",
        hiddenOnMobile && "hidden md:flex",
        className
      )}
      style={{ ["--list-column-width" as string]: `${widthPx}px` }}
    >
      {children}
      <div
        role="separator"
        aria-orientation="vertical"
        aria-labelledby={labelId}
        aria-valuemin={MIN_WIDTH_PX}
        aria-valuemax={MAX_WIDTH_PX}
        aria-valuenow={Math.round(widthPx)}
        tabIndex={0}
        id={labelId}
        aria-label="Resize List Column Width"
        className={cn(
          "pointer-events-none absolute inset-y-0 right-0 z-20 hidden w-px md:block",
          "touch-none select-none cursor-col-resize",
          "before:pointer-events-auto before:absolute before:inset-y-0 before:right-0 before:z-10 before:w-3 before:translate-x-1/2 before:bg-transparent",
          "after:pointer-events-none after:absolute after:inset-y-0 after:right-0 after:w-px after:bg-transparent hover:after:bg-border focus-visible:after:bg-ring"
        )}
        onPointerDown={onPointerDown}
        onKeyDown={onKeyDown}
      />
    </aside>
  );
}

export const READER_LIST_COLUMN_WIDTH_KEY =
  "the-social-wire.reader-list-column-width.v1";
