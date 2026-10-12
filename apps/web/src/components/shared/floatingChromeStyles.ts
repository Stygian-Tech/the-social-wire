/** Shared floating surface; globals.css owns glass, fallback, and accessibility. */
export const floatingGlassClasses =
  "floating-glass rounded-2xl border border-border/60";

/** Lighter glass for top controls and bottom navigation over scrolling content. */
export const floatingGlassBarClasses = `${floatingGlassClasses} floating-glass-bar`;
