"use client";

import { useEffect, useState } from "react";
import { socialRelativeTime } from "./socialRelativeTime";

export function SocialPostTimestamp({ timestamp }: { timestamp: string }) {
  const [now, setNow] = useState(Date.now);
  const date = new Date(timestamp);
  const milliseconds = date.getTime();
  useEffect(() => {
    if (!Number.isFinite(milliseconds)) return;
    // Fresh posts tick in seconds; older posts need only a minute-level refresh.
    const timer = setTimeout(() => setNow(Date.now()), now - milliseconds < 60_000 ? 1_000 : 60_000);
    return () => clearTimeout(timer);
  }, [milliseconds, now]);
  if (!Number.isFinite(milliseconds)) return null;
  return <time dateTime={date.toISOString()} title={date.toLocaleString()} suppressHydrationWarning className="ml-auto self-start shrink-0 text-xs tabular-nums text-muted-foreground">{socialRelativeTime(milliseconds, now)}</time>;
}
