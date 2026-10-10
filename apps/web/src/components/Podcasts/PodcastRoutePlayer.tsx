"use client";
import { usePodcastPlayer } from "./PodcastPlayerProvider";
import { PodcastPlayerView } from "./PodcastPlayerView";

/** Route-owned chrome; the app-lifetime provider keeps audio running elsewhere. */
export function PodcastRoutePlayer() {
  return <PodcastPlayerView player={usePodcastPlayer()} />;
}
