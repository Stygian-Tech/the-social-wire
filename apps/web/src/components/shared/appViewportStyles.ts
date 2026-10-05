/** Keep bounded route panes above persistent playback chrome. */
export const appViewportHeightClasses =
  "h-[calc(100svh-var(--environment-banner-height,0px)-var(--podcast-player-height,0px))] min-h-[calc(100svh-var(--environment-banner-height,0px)-var(--podcast-player-height,0px))] max-h-[calc(100svh-var(--environment-banner-height,0px)-var(--podcast-player-height,0px))]";

// The measured player occupancy already includes mobile navigation and its safe area.
export const appMobileNavigationPaddingClasses =
  "pb-[max(0px,calc(4rem+env(safe-area-inset-bottom)-var(--podcast-player-height,0px)))] md:pb-0";
