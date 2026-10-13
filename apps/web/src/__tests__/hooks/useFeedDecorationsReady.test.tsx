import { afterEach, expect, it } from "bun:test";
import { act, cleanup, renderHook } from "@testing-library/react";
import { useFeedDecorationsReady } from "@/hooks/useFeedDecorationsReady";

const restores: Array<() => void> = [];
afterEach(() => { cleanup(); for (const restore of restores.splice(0)) restore(); });

function scheduler() {
  const observers: Array<{ publish: PerformanceObserverCallback; disconnected: boolean }> = [];
  const idle: Array<{ callback: IdleRequestCallback; cancelled: boolean }> = [];
  const replace = (host: object, name: string, value: unknown) => {
    const original = Object.getOwnPropertyDescriptor(host, name);
    Object.defineProperty(host, name, { configurable: true, value });
    restores.push(() => { if (original) Object.defineProperty(host, name, original); else Reflect.deleteProperty(host, name); });
  };
  replace(globalThis, "PerformanceObserver", class {
    record: typeof observers[number];
    constructor(publish: PerformanceObserverCallback) { this.record = { publish, disconnected: false }; observers.push(this.record); }
    observe() {}
    disconnect() { this.record.disconnected = true; }
  });
  replace(window, "requestIdleCallback", (callback: IdleRequestCallback) => { idle.push({ callback, cancelled: false }); return idle.length; });
  replace(window, "cancelIdleCallback", (id: number) => { idle[id - 1].cancelled = true; });
  const publish = (index: number, scope: string) => act(() => observers[index].publish({ getEntries: () => [{ name: "socialwire.feed.first-content", detail: { scope } }] } as unknown as PerformanceObserverEntryList, {} as PerformanceObserver));
  const runIdle = (index: number) => act(() => idle[index].callback({ didTimeout: false, timeRemaining: () => 10 }));
  return { observers, idle, publish, runIdle };
}

it("keeps cached decoration out of the story frame and releases once during idle for the matching feed", () => {
  const clock = scheduler();
  const { result } = renderHook(() => useFeedDecorationsReady("sports:all:viewer", true));
  expect(result.current).toBe(false);
  clock.publish(0, "finance:all:viewer");
  expect(clock.idle).toHaveLength(0);
  clock.publish(0, "sports:all:viewer");
  clock.publish(0, "sports:all:viewer");
  expect(clock.idle).toHaveLength(1);
  expect(result.current).toBe(false);
  clock.runIdle(0);
  expect(result.current).toBe(true);
});

it("cancels queued decoration when the viewer or feed changes, including already-dispatched stale callbacks", () => {
  const clock = scheduler();
  const { result, rerender, unmount } = renderHook(({ scope }) => useFeedDecorationsReady(scope, true), { initialProps: { scope: "sports:all:first" } });
  clock.publish(0, "sports:all:first");
  rerender({ scope: "sports:all:second" });
  expect(clock.observers[0].disconnected).toBe(true);
  expect(clock.idle[0].cancelled).toBe(true);
  clock.runIdle(0);
  expect(result.current).toBe(false);
  clock.publish(1, "sports:all:second");
  clock.runIdle(1);
  expect(result.current).toBe(true);
  rerender({ scope: "sports:team:second" });
  expect(result.current).toBe(false);
  clock.publish(2, "sports:team:second");
  unmount();
  expect(clock.idle[2].cancelled).toBe(true);
});

it("keeps controls available for empty feeds that cannot emit a story frame", () => {
  const clock = scheduler();
  const { result } = renderHook(() => useFeedDecorationsReady("sports:empty", false));
  expect(result.current).toBe(true);
  expect(clock.observers).toHaveLength(0);
});

it("does not reuse a previous scope release when switching away and immediately returning", () => {
  const clock = scheduler();
  const { result, rerender } = renderHook(({ scope }) => useFeedDecorationsReady(scope, true), { initialProps: { scope: "finance:first" } });
  clock.publish(0, "finance:first");
  clock.runIdle(0);
  expect(result.current).toBe(true);
  rerender({ scope: "finance:second" });
  expect(result.current).toBe(false);
  rerender({ scope: "finance:first" });
  expect(result.current).toBe(false);
  clock.publish(2, "finance:first");
  clock.runIdle(1);
  expect(result.current).toBe(true);
});
