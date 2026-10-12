"use client";

import { useEffect, useState } from "react";

/** Keep each deferred sidebar subtree's first render consistent with its server markup. */
export function useSidebarMounted() {
  const [mounted, setMounted] = useState(false);
  useEffect(() => {
    let active = true;
    queueMicrotask(() => { if (active) setMounted(true); });
    return () => { active = false; };
  }, []);
  return mounted;
}
