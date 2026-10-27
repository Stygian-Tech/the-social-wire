import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, renderHook } from "@testing-library/react";
import { useVisibleFeedRefresh } from "@/hooks/useVisibleFeedRefresh";

let tick: () => void;
const restores: (() => void)[] = [];
beforeEach(() => {
  const descriptor = Object.getOwnPropertyDescriptor(document, "visibilityState");
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  restores.push(() => {
    if (descriptor) Object.defineProperty(document, "visibilityState", descriptor);
    else Reflect.deleteProperty(document, "visibilityState");
  });
  const interval = spyOn(window, "setInterval").mockImplementation(((callback: () => void) => { tick = callback; return 123; }) as typeof window.setInterval);
  const clear = spyOn(window, "clearInterval").mockImplementation(() => {});
  restores.push(() => interval.mockRestore(), () => clear.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
const flush = async () => { await act(async () => { await Promise.resolve(); }); };

it("refreshes visible feeds on interval and focus without overlapping requests", async () => {
  let finish!: () => void;
  const refresh = mock(() => new Promise<void>(resolve => { finish = resolve; }));
  renderHook(() => useVisibleFeedRefresh("viewer:subscribed", refresh));
  act(() => { tick(); window.dispatchEvent(new window.Event("focus")); document.dispatchEvent(new window.Event("visibilitychange")); });
  expect(refresh).toHaveBeenCalledTimes(1);
  finish(); await flush();
  act(() => window.dispatchEvent(new window.Event("focus")));
  expect(refresh).toHaveBeenCalledTimes(2);
  finish(); await flush();
});

it("skips hidden feeds and aborts the previous account/scope on navigation", async () => {
  const signals: AbortSignal[] = [];
  const refresh = mock(async (signal: AbortSignal) => { signals.push(signal); });
  const { rerender, unmount } = renderHook(({ scope }) => useVisibleFeedRefresh(scope, refresh), { initialProps: { scope: "alice:subscribed" } });
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
  act(() => tick()); expect(refresh).not.toHaveBeenCalled();
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  act(() => document.dispatchEvent(new window.Event("visibilitychange"))); await flush();
  rerender({ scope: "bob:following" }); expect(signals[0].aborted).toBe(true);
  act(() => tick()); await flush();
  unmount(); expect(signals[1].aborted).toBe(true);
  act(() => window.dispatchEvent(new window.Event("focus")));
  expect(refresh).toHaveBeenCalledTimes(2);
});

it("uses the latest callback and retries after background failure", async () => {
  const first = mock(async (): Promise<void> => { throw new Error("offline"); });
  const latest = mock(async () => {});
  const { rerender } = renderHook(({ refresh }) => useVisibleFeedRefresh("scope", refresh), { initialProps: { refresh: first } });
  act(() => tick()); await flush(); rerender({ refresh: latest });
  act(() => tick()); await flush();
  expect(first).toHaveBeenCalledTimes(1); expect(latest).toHaveBeenCalledTimes(1);
});

it("releases a stalled refresh at its deadline even when the callback ignores cancellation", async () => {
  const deadline = new AbortController();
  const timeout = spyOn(AbortSignal, "timeout").mockReturnValue(deadline.signal);
  restores.push(() => timeout.mockRestore());
  const refresh = mock(() => new Promise<void>(() => {}));
  renderHook(() => useVisibleFeedRefresh("scope", refresh));
  act(() => tick());
  deadline.abort(new DOMException("Timed out", "TimeoutError"));
  await flush();
  timeout.mockReturnValue(new AbortController().signal);
  act(() => tick());
  expect(refresh).toHaveBeenCalledTimes(2);
});
