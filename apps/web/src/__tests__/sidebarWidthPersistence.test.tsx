import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from "@testing-library/react";
import { renderToString } from "react-dom/server";
import * as Mobile from "@/hooks/use-mobile";
import {
  SidebarProvider,
  SidebarResizeHandle,
  useSidebar,
} from "@/components/ui/sidebar";
import {
  SIDEBAR_WIDTH_STORAGE_KEY,
  loadSidebarWidth,
} from "@/lib/sidebarWidthStorage";

const restores: (() => void)[] = [];
beforeEach(() => {
  window.localStorage.removeItem(SIDEBAR_WIDTH_STORAGE_KEY);
  const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false);
  restores.push(() => mobile.mockRestore());
});
afterEach(() => {
  cleanup();
  restores
    .splice(0)
    .reverse()
    .forEach((restore) => restore());
  window.localStorage.removeItem(SIDEBAR_WIDTH_STORAGE_KEY);
});
function Width() {
  const { sidebarWidthPx } = useSidebar();
  return <output aria-label="Current Sidebar Width">{sidebarWidthPx}</output>;
}
function mount(defaultWidth = 208) {
  return render(
    <SidebarProvider defaultWidthPx={defaultWidth}>
      <Width />
      <SidebarResizeHandle />
    </SidebarProvider>,
  );
}
function pointer(target: HTMLElement, type: string, clientX: number) {
  const event = new window.Event(type, { bubbles: true });
  Object.defineProperties(event, {
    clientX: { value: clientX },
    pointerId: { value: 1 },
  });
  fireEvent(target, event);
}
describe("browser-wide sidebar width", () => {
  it("keeps server markup at the default and restores saved width after mounting without overwriting it", async () => {
    window.localStorage.setItem(SIDEBAR_WIDTH_STORAGE_KEY, "352");
    expect(
      renderToString(
        <SidebarProvider>
          <Width />
        </SidebarProvider>,
      ),
    ).toContain("208");
    const writes = spyOn(window.Storage.prototype, "setItem");
    restores.push(() => writes.mockRestore());
    mount();
    await waitFor(() =>
      expect(screen.getByLabelText("Current Sidebar Width").textContent).toBe(
        "352",
      ),
    );
    expect(writes).not.toHaveBeenCalled();
  });
  it("persists keyboard resizing and restores it in a different route's provider", async () => {
    const view = mount();
    await act(async () => {});
    fireEvent.keyDown(screen.getByRole("separator"), {
      key: "ArrowRight",
      shiftKey: true,
    });
    await waitFor(() =>
      expect(screen.getByLabelText("Current Sidebar Width").textContent).toBe(
        "232",
      ),
    );
    await waitFor(() =>
      expect(window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY)).toBe(
        "232",
      ),
    );
    view.unmount();
    mount(300);
    await waitFor(() =>
      expect(screen.getByLabelText("Current Sidebar Width").textContent).toBe(
        "232",
      ),
    );
  });
  for (const [raw, expected] of [
    ["broken", 208],
    ["null", 208],
    ['"280"', 208],
    ["1e999", 208],
    ["40", 200],
    ["999", 480],
  ] as const) {
    it(`handles stored ${raw} with width ${expected}`, async () => {
      window.localStorage.setItem(SIDEBAR_WIDTH_STORAGE_KEY, raw);
      mount();
      await waitFor(() =>
        expect(screen.getByLabelText("Current Sidebar Width").textContent).toBe(
          String(expected),
        ),
      );
    });
  }
  it("resizes even when local storage cannot be accessed", async () => {
    const descriptor = Object.getOwnPropertyDescriptor(window, "localStorage")!;
    Object.defineProperty(window, "localStorage", {
      configurable: true,
      get: () => {
        throw new Error("blocked");
      },
    });
    restores.push(() =>
      Object.defineProperty(window, "localStorage", descriptor),
    );
    mount();
    await act(async () => {});
    fireEvent.keyDown(screen.getByRole("separator"), { key: "ArrowRight" });
    await waitFor(() =>
      expect(screen.getByLabelText("Current Sidebar Width").textContent).toBe(
        "216",
      ),
    );
  });
  it("defers pointer writes until drag completion and flushes before a route unmount", async () => {
    const view = mount();
    await act(async () => {});
    const handle = screen.getByRole("separator");
    Object.assign(handle, {
      setPointerCapture: () => undefined,
      hasPointerCapture: () => true,
      releasePointerCapture: () => undefined,
    });
    const writes = spyOn(window.Storage.prototype, "setItem");
    restores.push(() => writes.mockRestore());
    pointer(handle, "pointerdown", 0);
    pointer(handle, "pointermove", 64);
    pointer(handle, "pointermove", 80);
    await waitFor(() =>
      expect(screen.getByLabelText("Current Sidebar Width").textContent).toBe(
        "288",
      ),
    );
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 140));
    });
    expect(writes).not.toHaveBeenCalled();
    fireEvent(window, new window.Event("pagehide"));
    expect(window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY)).toBe("288");
    pointer(handle, "pointerup", 80);
    view.unmount();
    expect(window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY)).toBe("288");
  });
  it("ignores failed reads from a storage implementation", () => {
    expect(
      loadSidebarWidth({
        getItem: () => {
          throw new Error("blocked");
        },
      }),
    ).toBeNull();
  });
  it("keeps the resized width when persistence fails because storage is full", async () => {
    mount();
    await act(async () => {});
    const write = spyOn(window.Storage.prototype, "setItem").mockImplementation(
      () => {
        throw new Error("quota");
      },
    );
    restores.push(() => write.mockRestore());
    fireEvent.keyDown(screen.getByRole("separator"), { key: "ArrowRight" });
    await waitFor(() => expect(write).toHaveBeenCalled());
    expect(screen.getByLabelText("Current Sidebar Width").textContent).toBe(
      "216",
    );
  });
  it("flushes a changed width on pagehide without saving an untouched default", async () => {
    mount();
    await act(async () => {});
    fireEvent(window, new window.Event("pagehide"));
    expect(window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY)).toBeNull();
    fireEvent.keyDown(screen.getByRole("separator"), { key: "ArrowRight" });
    await waitFor(() =>
      expect(screen.getByLabelText("Current Sidebar Width").textContent).toBe(
        "216",
      ),
    );
    fireEvent(window, new window.Event("pagehide"));
    expect(window.localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY)).toBe("216");
  });
});
