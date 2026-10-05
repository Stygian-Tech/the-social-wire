import { afterEach, expect, it } from "bun:test";
import { cleanup, render, act } from "@testing-library/react";
import { useSpringStyle } from "@/hooks/useSpringStyle";

const styles = (value: number) => ({ opacity: String(value) });
function Sample({ target }: { target: number }) { const ref = useSpringStyle(target, styles); return <div ref={ref} data-testid="spring" />; }
afterEach(cleanup);
it("reacts immediately to the system reduced-motion preference and cancels ongoing motion", () => {
  const original = Object.getOwnPropertyDescriptor(window, "matchMedia");
  let changed: (() => void) | undefined;
  const media = { matches: true, addEventListener: (_: string, callback: () => void) => { changed = callback; }, removeEventListener: () => {} };
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => media });
  try {
    const view = render(<Sample target={0} />);
    view.rerender(<Sample target={1} />);
    expect(view.getByTestId("spring").style.opacity).toBe("1");
    media.matches = false; act(() => changed?.());
    view.rerender(<Sample target={0} />);
    media.matches = true; act(() => changed?.());
    expect(view.getByTestId("spring").style.opacity).toBe("0");
  } finally { if (original) Object.defineProperty(window, "matchMedia", original); else Reflect.deleteProperty(window, "matchMedia"); }
});
