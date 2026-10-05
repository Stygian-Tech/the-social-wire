import type { PodcastState } from "./client";
/** Apply only edited fields to the newest server version; progress compares logical edit timestamps. */
export function mergePodcastPatch(
  state: PodcastState,
  patch: Partial<PodcastState>,
): PodcastState {
  const progress = { ...state.progress };
  for (const [id, value] of Object.entries(patch.progress ?? {})) {
    if (!progress[id] || value.updatedAt >= progress[id].updatedAt)
      progress[id] = value;
  }
  return { ...state, ...patch, progress };
}
