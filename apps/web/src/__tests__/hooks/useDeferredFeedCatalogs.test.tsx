import { afterEach, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { useDeferredFeedCatalogs } from "@/hooks/useDeferredFeedCatalogs";
import { useFinanceCatalog } from "@/hooks/useFinanceCatalog";
import * as Finance from "@/lib/financeFeedClient";

afterEach(cleanup);

it("holds inactive catalog requests until selected content paints and enables active destinations immediately", async () => {
  const originalObserver = Object.getOwnPropertyDescriptor(globalThis, "PerformanceObserver");
  let publish!: PerformanceObserverCallback;
  Object.defineProperty(globalThis, "PerformanceObserver", { configurable: true, value: class {
    constructor(callback: PerformanceObserverCallback) { publish = callback; }
    observe() {}
    disconnect() {}
  } });
  const fetch = spyOn(Finance, "getFinanceCatalog").mockResolvedValue({ enabled: true, available: true, widgetsEnabled: false, feeds: [] });
  const client = new QueryClient();
  function wrapper({ children }: { children: ReactNode }) { return <QueryClientProvider client={client}>{children}</QueryClientProvider>; }
  try {
    const { unmount, result } = renderHook(({ active }) => {
      const ready = useDeferredFeedCatalogs(true);
      return useFinanceCatalog({ enabled: active || ready });
    }, { wrapper, initialProps: { active: false } });
    expect(fetch).not.toHaveBeenCalled();
    act(() => publish({ getEntries: () => [{ name: "unrelated" }] } as unknown as PerformanceObserverEntryList, {} as PerformanceObserver));
    expect(fetch).not.toHaveBeenCalled();
    act(() => publish({ getEntries: () => [{ name: "socialwire.feed.first-content" }] } as unknown as PerformanceObserverEntryList, {} as PerformanceObserver));
    await waitFor(() => expect(result.current.data?.enabled).toBe(true));
    expect(fetch).toHaveBeenCalledTimes(1);
    unmount();
    client.clear();
    renderHook(({ active }) => {
      const ready = useDeferredFeedCatalogs(true);
      return useFinanceCatalog({ enabled: active || ready });
    }, { wrapper, initialProps: { active: true } });
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
  } finally {
    cleanup();
    client.clear();
    fetch.mockRestore();
    if (originalObserver) Object.defineProperty(globalThis, "PerformanceObserver", originalObserver);
    else Reflect.deleteProperty(globalThis, "PerformanceObserver");
  }
});
