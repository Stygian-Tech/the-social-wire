/** Extend the adjacent scroll pane behind glass while keeping its end content reachable. */
export function attachFloatingGlassScrollOverlay(surface: HTMLElement, edge: "top" | "bottom") {
  const parent = surface.parentElement;
  const scrollPane = edge === "top" ? surface.nextElementSibling : surface.previousElementSibling;
  if (!parent || !(scrollPane instanceof HTMLElement) || typeof ResizeObserver === "undefined") return;
  const nestedShell = edge === "top" && scrollPane.hasAttribute("data-feed-header-shell");
  if (!scrollPane.classList.contains("overflow-y-auto") && !nestedShell) return;

  const extentProperty = `--floating-glass-${edge}-extent`;
  const paddingProperty = `--floating-glass-${edge}-content-padding`;
  const marker = nestedShell ? "data-floating-glass-shell-top" : `data-floating-glass-scroll-${edge}`;
  const previousExtent = parent.style.getPropertyValue(extentProperty);
  const previousPadding = scrollPane.style.getPropertyValue(paddingProperty);
  const previousMarker = scrollPane.getAttribute(marker);
  const style = window.getComputedStyle(scrollPane);
  scrollPane.style.setProperty(paddingProperty, edge === "top" ? style.paddingTop : style.paddingBottom);
  scrollPane.setAttribute(marker, "true");

  const updateExtent = () => {
    const style = window.getComputedStyle(surface);
    const extent = surface.getBoundingClientRect().height +
      (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0);
    parent.style.setProperty(extentProperty, `${extent}px`);
  };
  updateExtent();
  const observer = new ResizeObserver(updateExtent);
  observer.observe(surface);
  window.addEventListener("resize", updateExtent);

  return () => {
    observer.disconnect();
    window.removeEventListener("resize", updateExtent);
    if (previousExtent) parent.style.setProperty(extentProperty, previousExtent);
    else parent.style.removeProperty(extentProperty);
    if (previousPadding) scrollPane.style.setProperty(paddingProperty, previousPadding);
    else scrollPane.style.removeProperty(paddingProperty);
    if (previousMarker === null) scrollPane.removeAttribute(marker);
    else scrollPane.setAttribute(marker, previousMarker);
  };
}

/** Measure grouped controls independently from an enclosing feed header. */
export function attachFloatingGlassControlsOverlay(controls: HTMLElement | null) {
  if (!controls) return;
  const parent = controls.parentElement;
  if (!parent || typeof ResizeObserver === "undefined") return;
  const property = "--floating-glass-controls-extent";
  const previous = parent.style.getPropertyValue(property);
  const updateExtent = () => {
    parent.style.setProperty(property, `${controls.getBoundingClientRect().height}px`);
  };
  updateExtent();
  const observer = new ResizeObserver(updateExtent);
  observer.observe(controls);
  return () => {
    observer.disconnect();
    if (previous) parent.style.setProperty(property, previous);
    else parent.style.removeProperty(property);
  };
}
