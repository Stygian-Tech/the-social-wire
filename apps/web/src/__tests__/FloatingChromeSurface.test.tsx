import { afterEach, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";

import { FloatingChromeSurface } from "@/components/shared/FloatingChromeSurface";

afterEach(cleanup);

it("preserves semantic landmarks, keyboard events, and ref cleanup without a wrapper", () => {
  const release = mock(() => undefined);
  const onKeyDown = mock(() => undefined);
  let mounted: HTMLElement | null = null;
  const view = render(
    <FloatingChromeSurface as="aside" aria-label="Trending" tabIndex={0} onKeyDown={onKeyDown}
      ref={node => { mounted = node; return release; }}>
      Stories
    </FloatingChromeSurface>,
  );
  const surface = screen.getByRole("complementary", { name: "Trending" });
  expect(mounted as HTMLElement | null).toBe(surface);
  expect(view.container.firstElementChild).toBe(surface);
  expect(surface.classList.contains("floating-glass")).toBe(true);
  fireEvent.keyDown(surface, { key: "ArrowDown" });
  expect(onKeyDown).toHaveBeenCalledTimes(1);
  view.unmount();
  expect(release).toHaveBeenCalledTimes(1);
});

it("keeps nonfloating sidebar variants plain and forwards native attributes", () => {
  const { container } = render(<FloatingChromeSurface floating={false} data-sidebar="sidebar" className="bg-sidebar">Navigation</FloatingChromeSurface>);
  const surface = container.firstElementChild!;
  expect(surface.tagName).toBe("DIV");
  expect(surface.getAttribute("data-sidebar")).toBe("sidebar");
  expect(surface.classList.contains("floating-glass")).toBe(false);
  expect(surface.classList.contains("bg-sidebar")).toBe(true);
});
