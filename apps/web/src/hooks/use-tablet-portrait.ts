"use client";

import { useEffect, useState } from "react";

export const TABLET_PORTRAIT_MEDIA_QUERY =
  "(min-width: 768px) and (max-width: 1100px) and (orientation: portrait)";

export function useIsTabletPortrait(): boolean {
  const [matches, setMatches] = useState(false);

  useEffect(() => {
    const mediaQuery = window.matchMedia(TABLET_PORTRAIT_MEDIA_QUERY);
    const update = () => setMatches(mediaQuery.matches);

    update();
    mediaQuery.addEventListener("change", update);
    return () => mediaQuery.removeEventListener("change", update);
  }, []);

  return matches;
}
