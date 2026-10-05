"use client";

import {
  useCallback,
  useEffect,
  useRef,
  useState,
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
export function usePersistentSidebarWidth(
  defaultWidth: number,
  resizing: boolean,
): [number, Dispatch<SetStateAction<number>>] {
  const [state, setState] = useState(() => ({
    width: clampSidebarWidth(defaultWidth),
    restored: false,
    changed: false,
  }));
  const latest = useRef({
    width: clampSidebarWidth(defaultWidth),
    changed: false,
  });
  useEffect(() => {
    let cancelled = false;
    const storage = browserStorage();
    const width = storage ? loadSidebarWidth(storage) : null;
    queueMicrotask(() => {
      if (!cancelled)
        setState((previous) =>
          previous.restored
            ? previous
            : { ...previous, width: width ?? previous.width, restored: true },
        );
    });
    return () => {
      cancelled = true;
    };
  }, []);
  useEffect(() => {
    latest.current = { width: state.width, changed: state.changed };
  }, [state.width, state.changed]);
  useEffect(() => {
    if (!state.restored || !state.changed || resizing) return;
    const timer = window.setTimeout(() => {
      const storage = browserStorage();
      if (storage) saveSidebarWidth(storage, state.width);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [state.width, state.restored, state.changed, resizing]);
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
  const setWidth = useCallback<Dispatch<SetStateAction<number>>>((update) => {
    setState((previous) => ({
      width: clampSidebarWidth(
        typeof update === "function" ? update(previous.width) : update,
      ),
      restored: true,
      changed: true,
    }));
  }, []);
  return [state.width, setWidth];
}
