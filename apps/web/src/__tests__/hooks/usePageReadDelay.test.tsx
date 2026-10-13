import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, renderHook } from "@testing-library/react";
import { usePageReadDelay } from "@/hooks/usePageReadDelay";

let now: number;
let nextId: number;
let pending: Map<number, { at: number; run: () => void }>;
const restores: (() => void)[] = [];
beforeEach(() => {
  now = 0; nextId = 10000; pending = new Map();
  const originalSet = globalThis.setTimeout;
  const originalClear = globalThis.clearTimeout;
  const set = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void, delay?: number, ...args: unknown[]) => {
    if (delay !== 2000) return originalSet(callback, delay, ...args);
    const id = nextId++;
    pending.set(id, { at: now + delay, run: callback });
    return id;
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation(((id: number) => {
    if (!pending.delete(Number(id))) originalClear(id);
  }) as typeof clearTimeout);
  restores.push(() => set.mockRestore(), () => clear.mockRestore());
  const visibility = Object.getOwnPropertyDescriptor(document, "visibilityState");
  Object.defineProperty(document, "visibilityState", { configurable: true, value: "visible" });
  restores.push(() => { if (visibility) Object.defineProperty(document, "visibilityState", visibility); else Reflect.deleteProperty(document, "visibilityState"); });
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
function advance(ms: number) {
  act(() => {
    now += ms;
    for (const [id, timer] of [...pending]) if (timer.at <= now) { pending.delete(id); timer.run(); }
  });
}
function visibility(value: string) {
  act(() => {
    Object.defineProperty(document, "visibilityState", { configurable: true, value });
    document.dispatchEvent(new window.Event("visibilitychange"));
  });
}
it("waits two seconds, uses the latest callback, and does not repeat on render", () => {
  const first = mock(() => {}), latest = mock(() => {});
  const { rerender } = renderHook(({ callback }) => usePageReadDelay("alice:notification:1", true, callback), { initialProps: { callback: first } });
  advance(1999); expect(first).not.toHaveBeenCalled();
  rerender({ callback: latest }); advance(1);
  expect(first).not.toHaveBeenCalled(); expect(latest).toHaveBeenCalledTimes(1);
  rerender({ callback: latest }); advance(2000); expect(latest).toHaveBeenCalledTimes(1);
});
it("cancels on navigation and account/content changes and gives the new target its own delay", () => {
  const read = mock(() => {});
  const { rerender, unmount } = renderHook(({ key }) => usePageReadDelay(key, true, read), { initialProps: { key: "alice:conversation:one" } });
  advance(1500); rerender({ key: "bob:conversation:two" }); advance(500); expect(read).not.toHaveBeenCalled();
  advance(1499); expect(read).not.toHaveBeenCalled(); advance(1); expect(read).toHaveBeenCalledTimes(1);
  rerender({ key: "bob:conversation:three" }); advance(1000); unmount(); advance(2000); expect(read).toHaveBeenCalledTimes(1);
});
it("requires continuous visible time and never reads a hidden tab", () => {
  const read = mock(() => {});
  renderHook(() => usePageReadDelay("alice:notification:1", true, read));
  advance(1500); visibility("hidden"); advance(5000); expect(read).not.toHaveBeenCalled();
  visibility("visible"); advance(1999); expect(read).not.toHaveBeenCalled(); advance(1); expect(read).toHaveBeenCalledTimes(1);
  visibility("hidden"); visibility("visible"); advance(2000); expect(read).toHaveBeenCalledTimes(1);
});
it("waits until enabled and cancels if the content becomes unavailable", () => {
  const read = mock(() => {});
  const { rerender } = renderHook(({ enabled }) => usePageReadDelay("alice:conversation:1", enabled, read), { initialProps: { enabled: false } });
  advance(3000); expect(read).not.toHaveBeenCalled();
  rerender({ enabled: true }); advance(1500); rerender({ enabled: false }); advance(2000); expect(read).not.toHaveBeenCalled();
  rerender({ enabled: true }); advance(2000); expect(read).toHaveBeenCalledTimes(1);
});
