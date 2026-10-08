import { expect, it, mock, spyOn } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { FinanceReader } from "@/components/FinanceReader";
import * as AuthHook from "@/hooks/useAuth";
import * as WireFeed from "@/lib/wireFeedClient";

it("keeps the closed Finance reader idle without requesting article detail", () => {
  const globals = ["HTMLElement", "Element", "Node", "DOMRect"] as const;
  const previous = globals.map(name => Object.getOwnPropertyDescriptor(globalThis, name));
  globals.forEach(name => Object.defineProperty(globalThis, name, {
    configurable: true, value: window[name],
  }));
  const auth = spyOn(AuthHook, "useAuth").mockReturnValue({
    session: null,
    getOAuthSession: () => null,
    oauthSessionReloadSeq: 0,
  } as ReturnType<typeof AuthHook.useAuth>);
  const detail = spyOn(WireFeed, "getWireItem");
  const onClose = mock(() => {});
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  try {
    render(<QueryClientProvider client={client}>
      <FinanceReader entry={null} hidePerformance={false} widgetsEnabled={false} onClose={onClose} />
    </QueryClientProvider>);
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(detail).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  } finally {
    cleanup();
    client.clear();
    detail.mockRestore();
    auth.mockRestore();
    globals.forEach((name, index) => {
      if (previous[index]) Object.defineProperty(globalThis, name, previous[index]!);
      else Reflect.deleteProperty(globalThis, name);
    });
  }
});
