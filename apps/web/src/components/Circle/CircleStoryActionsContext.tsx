"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";

import { useSetCircleItemHidden } from "@/hooks/useCircleFeed";

type CircleStoryActions = {
  errorMessage: string | null;
  hide: (storyId: string) => void;
  undo: (storyId: string) => void;
  isHidden: (storyId: string) => boolean;
  isPending: (storyId: string) => boolean;
};

const CircleStoryActionsContext = createContext<CircleStoryActions | null>(null);
const UNDO_WINDOW_MS = 8_000;

export function CircleStoryActionsProvider({
  children,
  refresh,
}: {
  children: ReactNode;
  refresh: () => Promise<unknown>;
}) {
  const mutation = useSetCircleItemHidden();
  const setHidden = useCallback(
    (input: { storyId: string; hidden: boolean }) =>
      mutation.mutateAsync(input),
    [mutation],
  );
  return (
    <CircleStoryActionsStateProvider refresh={refresh} setHidden={setHidden}>
      {children}
    </CircleStoryActionsStateProvider>
  );
}

export function CircleStoryActionsStateProvider({
  children,
  refresh,
  setHidden,
}: {
  children: ReactNode;
  refresh: () => Promise<unknown>;
  setHidden: (input: {
    storyId: string;
    hidden: boolean;
  }) => Promise<unknown>;
}) {
  const [hiddenStoryIds, setHiddenStoryIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [pendingStoryIds, setPendingStoryIds] = useState<Set<string>>(
    () => new Set(),
  );
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const commitTimers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const actionVersions = useRef(new Map<string, number>());

  useEffect(
    () => () => {
      for (const timer of commitTimers.current.values()) clearTimeout(timer);
      commitTimers.current.clear();
    },
    [],
  );

  const markPending = useCallback((storyId: string, pending: boolean) => {
    setPendingStoryIds((current) => {
      const next = new Set(current);
      if (pending) next.add(storyId);
      else next.delete(storyId);
      return next;
    });
  }, []);

  const hide = useCallback(
    (storyId: string) => {
      if (hiddenStoryIds.has(storyId)) return;
      const actionVersion = (actionVersions.current.get(storyId) ?? 0) + 1;
      actionVersions.current.set(storyId, actionVersion);
      setErrorMessage(null);
      setHiddenStoryIds((current) => new Set(current).add(storyId));
      markPending(storyId, true);
      void setHidden({ storyId, hidden: true })
        .then(() => {
          if (actionVersions.current.get(storyId) !== actionVersion) return;
          const timer = setTimeout(() => {
            commitTimers.current.delete(storyId);
            void refresh()
              .then(() => {
                setHiddenStoryIds((current) => {
                  const next = new Set(current);
                  next.delete(storyId);
                  return next;
                });
              })
              .catch((error) => {
                setErrorMessage(
                  error instanceof Error
                    ? error.message
                    : "Could not refresh Your Circle.",
                );
              });
          }, UNDO_WINDOW_MS);
          commitTimers.current.set(storyId, timer);
        })
        .catch((error) => {
          setHiddenStoryIds((current) => {
            const next = new Set(current);
            next.delete(storyId);
            return next;
          });
          setErrorMessage(
            error instanceof Error ? error.message : "Could not hide this story.",
          );
        })
        .finally(() => markPending(storyId, false));
    }, [hiddenStoryIds, markPending, refresh, setHidden],
  );

  const undo = useCallback(
    (storyId: string) => {
      actionVersions.current.set(
        storyId,
        (actionVersions.current.get(storyId) ?? 0) + 1,
      );
      const timer = commitTimers.current.get(storyId);
      if (timer) clearTimeout(timer);
      commitTimers.current.delete(storyId);
      setErrorMessage(null);
      setHiddenStoryIds((current) => {
        const next = new Set(current);
        next.delete(storyId);
        return next;
      });
      markPending(storyId, true);
      void setHidden({ storyId, hidden: false })
        .then(() => refresh())
        .catch((error) => {
          setHiddenStoryIds((current) => new Set(current).add(storyId));
          setErrorMessage(
            error instanceof Error
              ? error.message
              : "Could not restore this story.",
          );
        })
        .finally(() => markPending(storyId, false));
    }, [markPending, refresh, setHidden],
  );

  const value = useMemo<CircleStoryActions>(
    () => ({
      errorMessage,
      hide,
      undo,
      isHidden: (storyId) => hiddenStoryIds.has(storyId),
      isPending: (storyId) => pendingStoryIds.has(storyId),
    }),
    [errorMessage, hiddenStoryIds, hide, pendingStoryIds, undo],
  );

  return (
    <CircleStoryActionsContext.Provider value={value}>
      {children}
    </CircleStoryActionsContext.Provider>
  );
}

export function useCircleStoryActions(): CircleStoryActions | null {
  return useContext(CircleStoryActionsContext);
}
