"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { loadComposerDraft, saveComposerDraft } from "@/lib/composerDraftStorage";
import type { ThreadPublication, ThreadSegment } from "@/lib/blueskyThreadClient";

export function useComposerDraft(did: string, context: string, segments: ThreadSegment[], publicationRef: React.RefObject<ThreadPublication | undefined>, restore: (segments: ThreadSegment[]) => void, enabled = true) {
  const [loaded, setLoaded] = useState(false);
  const [storageError, setStorageError] = useState<string>();
  const restoreRef = useRef(restore);
  const latest = useRef(segments);
  useLayoutEffect(() => { restoreRef.current = restore; latest.current = segments; });
  const cleared = useRef(false);
  useEffect(() => {
    if (!enabled || loaded) return;
    let active = true;
    void loadComposerDraft(did, context).then(draft => {
      if (!active) return;
      if (draft) { publicationRef.current = draft.publication; restoreRef.current(draft.segments); }
    }).catch(() => { if (active) setStorageError("Draft Could Not Be Restored. Storage Is Unavailable."); }).finally(() => { if (active) setLoaded(true); });
    return () => { active = false; };
  }, [did, context, publicationRef, enabled, loaded]);

  async function checkpoint() {
    try {
      await saveComposerDraft(did, context, { version: 1, did, segments: latest.current, publication: publicationRef.current });
      setStorageError(undefined);
    } catch {
      setStorageError("Draft Could Not Be Saved. Keep This Window Open And Retry.");
      throw new Error("Draft Could Not Be Saved. Retry Before Posting.");
    }
  }
  useEffect(() => {
    if (!loaded) return;
    if (publicationRef.current && !publicationRef.current.segments.some(item => item.attempted)) publicationRef.current = undefined;
    if (cleared.current) { cleared.current = false; return; }
    // Start a durable save on every edit, including dismissal; no timer loses the final edit.
    void checkpoint().catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps -- checkpoint reads the latest refs.
  }, [segments, loaded]);
  async function clear() {
    cleared.current = true;
    await saveComposerDraft(did, context);
  }
  return { loaded, storageError, checkpoint, clear };
}
