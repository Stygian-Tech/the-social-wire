import { afterEach, expect, it, spyOn } from "bun:test";
import { cleanup, renderHook, act } from "@testing-library/react";
import { useFeedFirstContentTiming } from "@/hooks/useFeedFirstContentTiming";

afterEach(cleanup);

it("measures visible content after the rendered frame and records each scope once", () => {
  const frames: FrameRequestCallback[] = [];
  const originalRequest = Object.getOwnPropertyDescriptor(globalThis, "requestAnimationFrame");
  const originalCancel = Object.getOwnPropertyDescriptor(globalThis, "cancelAnimationFrame");
  Object.defineProperty(globalThis, "requestAnimationFrame", { configurable: true, writable: true, value: (callback: FrameRequestCallback) => { frames.push(callback); return frames.length; } });
  Object.defineProperty(globalThis, "cancelAnimationFrame", { configurable: true, writable: true, value: () => {} });
  const originalMeasure = Object.getOwnPropertyDescriptor(performance, "measure");
  const measure = spyOn(performance, "measure");
  const samples = () => measure.mock.calls.filter(([name]) => name === "socialwire.feed.first-content");
  try {
    const { rerender } = renderHook(({ ready, scope }) => useFeedFirstContentTiming(scope, ready, true), { initialProps: { ready: false, scope: "finance" } });
    expect(frames).toHaveLength(0);
    rerender({ ready: true, scope: "finance" });
    act(() => frames.shift()!(0));
    expect(samples()).toHaveLength(0);
    act(() => frames.shift()!(16));
    expect(samples()).toHaveLength(1);
    expect(samples()[0]?.[0]).toBe("socialwire.feed.first-content");
    rerender({ ready: true, scope: "finance" });
    expect(frames).toHaveLength(0);
    rerender({ ready: true, scope: "sports" });
    act(() => frames.shift()!(32));
    act(() => frames.shift()!(48));
    expect(samples()).toHaveLength(2);
    expect(performance.getEntriesByName("socialwire.feed.first-content")).toHaveLength(1);
  } finally {
    cleanup();
    measure.mockRestore();
    if (originalMeasure) Object.defineProperty(performance, "measure", originalMeasure);
    else Reflect.deleteProperty(performance, "measure");
    if (originalRequest) Object.defineProperty(globalThis, "requestAnimationFrame", originalRequest);
    else Reflect.deleteProperty(globalThis, "requestAnimationFrame");
    if (originalCancel) Object.defineProperty(globalThis, "cancelAnimationFrame", originalCancel);
    else Reflect.deleteProperty(globalThis, "cancelAnimationFrame");
  }
});
