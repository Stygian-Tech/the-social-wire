"use client";

import {
  useCallback,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type Dispatch,
  type SetStateAction,
} from "react";
import {
  clampSidebarWidth,
  loadSidebarWidth,
  saveSidebarWidth,
} from "@/lib/sidebarWidthStorage";

function browserStorage(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

const subscribe = () => () => {};

export function usePersistentSidebarWidth(
  defaultWidth: number,
  resizing: boolean,
): [number, Dispatch<SetStateAction<number>>] {
  // Match server markup during hydration, but read the saved width immediately
  // when a different section mounts its own sidebar provider in the browser.
  const savedWidth = useSyncExternalStore(
    subscribe,
    () => {
      const storage = browserStorage();
      return (
        (storage ? loadSidebarWidth(storage) : null) ??
        clampSidebarWidth(defaultWidth)
      );
    },
    () => clampSidebarWidth(defaultWidth),
  );
  const [changedWidth, setChangedWidth] = useState<number | null>(null);
  const width = changedWidth ?? savedWidth;
  const changed = changedWidth !== null;
  const latest = useRef({ width, changed });
  useEffect(() => {
    latest.current = { width, changed };
  }, [width, changed]);
  useEffect(() => {
    if (!changed || resizing) return;
    const timer = window.setTimeout(() => {
      const storage = browserStorage();
      if (storage) saveSidebarWidth(storage, width);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [width, changed, resizing]);
  useEffect(() => {
    const flush = () => {
      const storage = browserStorage();
      if (storage && latest.current.changed)
        saveSidebarWidth(storage, latest.current.width);
    };
    window.addEventListener("pagehide", flush);
    return () => {
      window.removeEventListener("pagehide", flush);
      // Save before a route change or page lifecycle ends the debounce window.
      flush();
    };
  }, []);
  const setWidth = useCallback<Dispatch<SetStateAction<number>>>(
    (update) => {
      setChangedWidth((previous) =>
        clampSidebarWidth(
          typeof update === "function" ? update(previous ?? savedWidth) : update,
        ),
      );
    },
    [savedWidth],
  );
  return [width, setWidth];
}
