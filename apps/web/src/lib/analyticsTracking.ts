export type AnalyticsSurface = "social-feed" | "article-feed" | "post-viewer" | "article-reader" | "messages";
export type AnalyticsEvent = { subjectUri: string; event: "impression" | "view" | "outbound_click"; surface: AnalyticsSurface };

const surfaces = new Set<AnalyticsSurface>(["social-feed", "article-feed", "post-viewer", "article-reader", "messages"]);
export function analyticsSubject(element: Element): { subjectUri: string; surface: AnalyticsSurface } | undefined {
  if (element.closest("[data-analytics-ignore]")) return;
  const subjectUri = element.getAttribute("data-analytics-subject") ?? "";
  const surface = element.getAttribute("data-analytics-surface") as AnalyticsSurface;
  if (!/^at:\/\/did:[a-z]+:[^/?#\s]+\/(app\.bsky\.feed\.post|site\.standard\.document)\/[a-zA-Z0-9._~:-]{1,512}$/.test(subjectUri) || !surfaces.has(surface)) return;
  return { subjectUri, surface };
}

/** Visible for a second with at least half the card (or 200px for tall cards) on screen. */
export function analyticsExposureVisible(entry: Pick<IntersectionObserverEntry, "isIntersecting" | "boundingClientRect" | "intersectionRect">): boolean {
  return entry.isIntersecting && entry.intersectionRect.height >= Math.min(entry.boundingClientRect.height / 2, 200) && entry.intersectionRect.width >= entry.boundingClientRect.width / 2;
}

/** No link URLs or message text leave the browser. Counts are best-effort, signed-in traffic. */
export function observeAnalyticsTraffic(emit: (event: AnalyticsEvent) => void): () => void {
  if (typeof IntersectionObserver === "undefined") return () => {};
  const observed = new Set<Element>();
  const timers = new Map<Element, ReturnType<typeof setTimeout>>();
  const sent = new Set<string>();
  const send = (event: AnalyticsEvent) => {
    const key = `${new Date().toISOString().slice(0, 10)}:${event.subjectUri}:${event.event}`;
    if (sent.has(key)) return;
    sent.add(key); emit(event);
  };
  const clear = (element: Element) => { clearTimeout(timers.get(element)); timers.delete(element); };
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) {
      clear(entry.target);
      const subject = analyticsSubject(entry.target);
      if (!subject || document.visibilityState === "hidden" || !analyticsExposureVisible(entry)) continue;
      timers.set(entry.target, setTimeout(() => {
        timers.delete(entry.target);
        if (!entry.target.isConnected || document.visibilityState === "hidden" || JSON.stringify(analyticsSubject(entry.target)) !== JSON.stringify(subject)) return;
        send({ ...subject, event: "impression" });
        if (subject.surface === "post-viewer" || subject.surface === "article-reader") send({ ...subject, event: "view" });
      }, 1000));
    }
  }, { threshold: [0, 0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 1] });
  const reconcile = () => {
    for (const element of document.querySelectorAll("[data-analytics-subject]")) {
      if (!observed.has(element)) { observed.add(element); observer.observe(element); }
    }
    for (const element of observed) if (!element.isConnected) { observer.unobserve(element); observed.delete(element); clear(element); }
  };
  const mutation = new MutationObserver(records => {
    // Reader panes and virtual lists can reuse a visible element for new content.
    // Restart its exposure instead of inheriting the previous subject's dwell time.
    const changed = new Set(records.filter(record => record.type === "attributes").map(record => record.target));
    for (const target of changed) {
      if (!(target instanceof Element) || !observed.has(target)) continue;
      clear(target); observer.unobserve(target); observer.observe(target);
    }
    reconcile();
  });
  mutation.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-analytics-subject", "data-analytics-surface"] });
  reconcile();
  const click = (event: MouseEvent) => {
    if (event.defaultPrevented || document.visibilityState === "hidden" || !(event.target instanceof Element)) return;
    const anchor = event.target.closest("a[href]");
    const card = anchor?.closest("[data-analytics-subject]");
    const subject = card && analyticsSubject(card);
    if (!anchor || !subject) return;
    try {
      const url = new URL(anchor.getAttribute("href") ?? "", window.location.href);
      if (!["https:", "http:"].includes(url.protocol) || url.origin === window.location.origin) return;
      send({ ...subject, event: "outbound_click" });
    } catch { /* Invalid links are not measured. */ }
  };
  const visibility = () => {
    for (const element of timers.keys()) clear(element);
    if (document.visibilityState !== "hidden") { for (const element of observed) { observer.unobserve(element); observer.observe(element); } }
  };
  document.addEventListener("click", click);
  document.addEventListener("visibilitychange", visibility);
  return () => {
    observer.disconnect(); mutation.disconnect();
    for (const element of timers.keys()) clear(element);
    document.removeEventListener("click", click);
    document.removeEventListener("visibilitychange", visibility);
  };
}
