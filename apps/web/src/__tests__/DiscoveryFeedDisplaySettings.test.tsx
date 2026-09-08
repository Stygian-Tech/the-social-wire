import { afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { DiscoveryFeedDisplaySettings } from "@/components/Account/DiscoveryFeedDisplaySettings";

afterEach(cleanup);

beforeAll(() => {
  for (const name of ["HTMLElement", "HTMLInputElement", "Element", "Node", "PointerEvent"] as const) {
    Object.defineProperty(globalThis, name, { configurable: true, value: window[name] });
  }
});

describe("discovery feed display settings", () => {
  it("shows independently controlled visibility switches without unread count switches", () => {
    const onVisibilityChange = mock(() => undefined);
    const { rerender } = render(
      <DiscoveryFeedDisplaySettings
        preferences={{ showWire: true, showCircle: true }}
        disabled={false}
        onVisibilityChange={onVisibilityChange}
      />,
    );
    fireEvent.click(screen.getByRole("switch", { name: "Show The Wire" }));
    expect(onVisibilityChange).toHaveBeenCalledWith("wire", false);
    rerender(
      <DiscoveryFeedDisplaySettings
        preferences={{ showWire: false, showCircle: true }}
        disabled={false}
        onVisibilityChange={onVisibilityChange}
      />,
    );
    expect(screen.getByRole("switch", { name: "Show The Wire" }).getAttribute("aria-checked")).toBe("false");
    expect(screen.getByRole("switch", { name: "Show Your Circle" }).getAttribute("aria-checked")).toBe("true");
    fireEvent.click(screen.getByRole("switch", { name: "Show Your Circle" }));
    expect(onVisibilityChange).toHaveBeenCalledWith("circle", false);
    fireEvent.click(screen.getByRole("switch", { name: "Show The Wire" }));
    expect(onVisibilityChange).toHaveBeenCalledWith("wire", true);
    expect(screen.getAllByRole("switch")).toHaveLength(2);
  });

  it("disables both switches while preferences are saving", () => {
    const onVisibilityChange = mock(() => undefined);
    render(
      <DiscoveryFeedDisplaySettings
        preferences={{ showWire: false, showCircle: false }}
        disabled
        onVisibilityChange={onVisibilityChange}
      />,
    );
    const wire = screen.getByRole("switch", { name: "Show The Wire" });
    expect(wire.getAttribute("aria-disabled")).toBe("true");
    expect(screen.getByRole("switch", { name: "Show Your Circle" }).getAttribute("aria-disabled")).toBe("true");
    fireEvent.click(wire);
    expect(onVisibilityChange).not.toHaveBeenCalled();
  });
});
