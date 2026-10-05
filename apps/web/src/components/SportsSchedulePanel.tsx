"use client";

import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { useSpringStyle } from "@/hooks/useSpringStyle";

const heightStyle = (height: number) => ({ height: `${Math.max(0, height)}px` });
/** Retains content and spring velocity so an interrupted collapse can reverse naturally. */
export function SportsSchedulePanel({ id, expanded, children }: { id: string; expanded: boolean; children: ReactNode }) {
  const content = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState(0);
  const spring = useSpringStyle(expanded ? height : 0, heightStyle, { snapFirstMeasurement: true });
  useLayoutEffect(() => {
    const element = content.current;
    if (!element) return;
    const measure = () => setHeight(element.getBoundingClientRect().height);
    measure();
    const observer = typeof ResizeObserver === "function" ? new ResizeObserver(measure) : undefined;
    observer?.observe(element);
    return () => observer?.disconnect();
  }, []);
  return <div id={id} ref={spring} aria-hidden={!expanded} inert={!expanded} className="overflow-hidden"><div ref={content}>{children}</div></div>;
}
