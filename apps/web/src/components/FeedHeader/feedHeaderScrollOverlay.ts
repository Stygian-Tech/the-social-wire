/** Let feed scroll panes, including the reader shell, pass behind their header. */
export function attachFeedHeaderScrollOverlay(header: HTMLElement) {
  const parent = header.parentElement;
  const scrollPane = header.nextElementSibling;
  if (!parent || !(scrollPane instanceof HTMLElement) ||
      (!scrollPane.classList.contains("overflow-y-auto") &&
       !scrollPane.hasAttribute("data-feed-header-shell")) ||
      typeof ResizeObserver === "undefined") return;

  const previousExtent = parent.style.getPropertyValue("--feed-header-extent");
  const previousPadding = scrollPane.style.getPropertyValue("--feed-header-content-padding");
  const previousMarker = scrollPane.getAttribute("data-feed-header-scroll");
  const contentPadding = window.getComputedStyle(scrollPane).paddingTop;
  scrollPane.style.setProperty("--feed-header-content-padding", contentPadding);
  if (!scrollPane.hasAttribute("data-feed-header-shell")) {
    scrollPane.setAttribute("data-feed-header-scroll", "true");
  }

  const updateExtent = () => {
    const style = window.getComputedStyle(header);
    const extent = header.getBoundingClientRect().height +
      (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0);
    parent.style.setProperty("--feed-header-extent", `${extent}px`);
  };
  updateExtent();
  const observer = new ResizeObserver(updateExtent);
  observer.observe(header);

  return () => {
    observer.disconnect();
    if (previousExtent) parent.style.setProperty("--feed-header-extent", previousExtent);
    else parent.style.removeProperty("--feed-header-extent");
    if (previousPadding) scrollPane.style.setProperty("--feed-header-content-padding", previousPadding);
    else scrollPane.style.removeProperty("--feed-header-content-padding");
    if (previousMarker === null) scrollPane.removeAttribute("data-feed-header-scroll");
    else scrollPane.setAttribute("data-feed-header-scroll", previousMarker);
  };
}
