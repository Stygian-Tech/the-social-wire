"use client";

import { useLayoutEffect, useRef } from "react";
import { APP_CHROME_GUTTER_PX } from "@/components/shared/appChromeStyles";

/** Constrain a sticky panel to the visible area of its owning scroll pane. */
export function useViewportSidebar(scrollHostSelector: string, minViewportWidth = 0, enabled = true) {
  const sidebar = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    const panel = sidebar.current;
    const scrollHost = panel?.closest<HTMLElement>(scrollHostSelector);
    if (!enabled || !panel || !scrollHost) return;
    let frame = 0;
    let topbar: HTMLElement | undefined;
    const measure = () => {
      frame = 0;
      if (window.innerWidth < minViewportWidth) {
        panel.style.removeProperty("top");
        panel.style.removeProperty("max-height");
        return;
      }
      const currentTopbar = scrollHost.querySelector<HTMLElement>(":scope > [data-topic-topbar]") ?? undefined;
      if (currentTopbar !== topbar) {
        if (topbar) observer?.unobserve(topbar);
        topbar = currentTopbar;
        if (topbar) observer?.observe(topbar);
      }
      const host = scrollHost.getBoundingClientRect();
      const barBottom = topbar?.getBoundingClientRect().bottom ?? host.top;
      const stickyOffset = Math.max(0, barBottom - host.top) + APP_CHROME_GUTTER_PX;
      const fixed = window.getComputedStyle(panel).position === "fixed";
      panel.style.top = `${fixed ? host.top + stickyOffset : stickyOffset}px`;
      const top = Math.max(panel.getBoundingClientRect().top, host.top + stickyOffset);
      const bottom = Math.min(window.innerHeight, host.bottom);
      panel.style.maxHeight = `${Math.max(0, bottom - top - APP_CHROME_GUTTER_PX)}px`;
    };
    const schedule = () => {
      if (typeof window.requestAnimationFrame !== "function") { measure(); return; }
      if (!frame) frame = window.requestAnimationFrame(measure);
    };
    const observer = typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(schedule);
    measure();
    scrollHost.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    observer?.observe(scrollHost);
    if (panel.parentElement) observer?.observe(panel.parentElement);
    // Schedules can load above this panel after its first layout measurement.
    const mutations = new window.MutationObserver(schedule);
    mutations.observe(scrollHost, { childList: true, subtree: true });
    return () => {
      scrollHost.removeEventListener("scroll", schedule);
      window.removeEventListener("resize", schedule);
      observer?.disconnect();
      mutations.disconnect();
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, [scrollHostSelector, minViewportWidth, enabled]);
  return sidebar;
}
