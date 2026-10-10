"use client";
import type { ReactNode } from "react";
import { PodcastRoutePlayer } from "./PodcastRoutePlayer";

export function PodcastContentPane({ children }: { children: ReactNode }) {
  return <div className="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden">
    <main className="min-h-0 min-w-0 flex-1 overflow-y-auto">{children}</main>
    <PodcastRoutePlayer />
  </div>;
}
