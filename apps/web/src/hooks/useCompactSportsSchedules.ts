"use client";

import { useLayoutEffect, useRef, useState } from "react";

/** Keep compact sticky schedules tied to the reader pane rather than window scrolling. */
export function useCompactSportsSchedules() {
  const section = useRef<HTMLElement>(null);
  const [compact, setCompact] = useState(false);
  useLayoutEffect(() => {
    const panel = section.current;
    if (!panel) return;
    const host = panel.closest<HTMLElement>("[data-sports-scroll]");
    if (!host) return;
    // Changing sticky-header height must not move the browser's anchor and trigger
    // another transition. The actual scroll offset stays under the user's control.
    const previousAnchoring = host.style.overflowAnchor;
    host.style.overflowAnchor = "none";
    let frame = 0;
    const measure = () => {
      frame = 0;
      setCompact(current => current ? host.scrollTop > 8 : host.scrollTop > 48);
    };
    const schedule = () => {
      if (typeof window.requestAnimationFrame !== "function") { measure(); return; }
      if (!frame) frame = window.requestAnimationFrame(measure);
    };
    measure();
    host.addEventListener("scroll", schedule, { passive: true });
    return () => {
      host.removeEventListener("scroll", schedule);
      host.style.overflowAnchor = previousAnchoring;
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, []);
  return { section, compact };
}
