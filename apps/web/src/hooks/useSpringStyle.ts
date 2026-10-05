"use client";

import { useCallback, useLayoutEffect, useRef } from "react";
import { SpringMotion } from "@/lib/springMotion";

type Styles = (value: number) => Record<string, string>;
/** Writes presentation styles without rendering every card on every frame. */
export function useSpringStyle(target: number, styles: Styles, options: { instant?: boolean; snapFirstMeasurement?: boolean; onRest?: () => void } = {}) {
  const motion = useRef<SpringMotion>(new SpringMotion(target));
  const node = useRef<HTMLElement | null>(null);
  const frame = useRef<number | undefined>(undefined);
  const previous = useRef<number | undefined>(undefined);
  const writer = useRef(styles);
  const reduced = useRef(false);
  const rest = useRef(options.onRest);
  const instant = useRef(options.instant);
  const measured = useRef(false);
  const write = useCallback(() => {
    for (const [property, value] of Object.entries(writer.current(motion.current.value))) node.current?.style.setProperty(property, value);
  }, []);
  const tick = useCallback(function step(timestamp: number) {
    const settled = motion.current.advance(previous.current == null ? 1 / 60 : (timestamp - previous.current) / 1000);
    previous.current = timestamp;
    write();
    if (!settled) frame.current = requestAnimationFrame(step);
    else { frame.current = undefined; previous.current = undefined; rest.current?.(); }
  }, [write]);
  const start = useCallback(() => {
    if (motion.current.value === motion.current.target && motion.current.velocity === 0) { write(); rest.current?.(); return; }
    if (reduced.current || instant.current || typeof requestAnimationFrame !== "function") { motion.current.finish(); write(); rest.current?.(); return; }
    if (frame.current == null) frame.current = requestAnimationFrame(tick);
  }, [tick, write]);
  const ref = useCallback((element: HTMLElement | null) => { node.current = element; write(); }, [write]);
  useLayoutEffect(() => { writer.current = styles; rest.current = options.onRest; instant.current = options.instant; motion.current.target = target; if (options.snapFirstMeasurement && !measured.current && target > 0) { measured.current = true; motion.current.finish(); write(); } else start(); }, [target, styles, options.onRest, options.instant, options.snapFirstMeasurement, start, write]);
  useLayoutEffect(() => {
    const media = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    const update = () => {
      reduced.current = media?.matches ?? false;
      if (reduced.current) {
        if (frame.current != null) cancelAnimationFrame(frame.current);
        frame.current = undefined; previous.current = undefined; motion.current.finish(); write(); rest.current?.();
      }
    };
    update(); media?.addEventListener?.("change", update);
    return () => { media?.removeEventListener?.("change", update); if (frame.current != null) cancelAnimationFrame(frame.current); };
  }, [write]);
  return ref;
}
