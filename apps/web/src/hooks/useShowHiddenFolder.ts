"use client";

import { useCallback, useEffect, useState } from "react";

export const SHOW_HIDDEN_FOLDER_STORAGE_KEY = "the-social-wire.show-hidden-folder";

/**
 * Client-only preference: whether the sidebar shows the "Hidden Publications" pseudo-folder.
 * Default false (folder hidden).
 */
export function useShowHiddenFolder() {
  const [showHiddenFolder, setShowHiddenFolderState] = useState(false);

  useEffect(() => {
    try {
      const raw = window.localStorage.getItem(SHOW_HIDDEN_FOLDER_STORAGE_KEY);
      setShowHiddenFolderState(raw === "true");
    } catch {
      // ignore
    }
  }, []);

  const setShowHiddenFolder = useCallback((next: boolean) => {
    setShowHiddenFolderState(next);
    try {
      window.localStorage.setItem(SHOW_HIDDEN_FOLDER_STORAGE_KEY, next ? "true" : "false");
    } catch {
      // ignore
    }
  }, []);

  return { showHiddenFolder, setShowHiddenFolder };
}
