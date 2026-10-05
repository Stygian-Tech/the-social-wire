/** Bound route panes to the viewport below the environment banner. */
export const appViewportHeightClasses =
  "h-[calc(100svh-var(--environment-banner-height,0px))] min-h-[calc(100svh-var(--environment-banner-height,0px))] max-h-[calc(100svh-var(--environment-banner-height,0px))]";

export const appMobileNavigationPaddingClasses =
  "pb-[calc(4rem+env(safe-area-inset-bottom))] md:pb-0";
