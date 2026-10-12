import { afterEach, expect, it, spyOn } from "bun:test";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { EnvironmentBanner } from "@/components/shared/EnvironmentBanner";

afterEach(cleanup);

it("reserves the actual wrapped banner height and shrinks again after resizing", () => {
  let height = 42;
  const previous = document.body.style.getPropertyValue("--environment-banner-height");
  document.body.style.setProperty("--environment-banner-height", "42px");
  const bounds = spyOn(window.HTMLElement.prototype, "getBoundingClientRect").mockImplementation(() => ({ height }) as DOMRect);
  try {
    const view = render(<EnvironmentBanner appEnv="dev" />);
    expect(document.body.style.getPropertyValue("--environment-banner-height")).toBe("42px");
    height = 82;
    fireEvent(window, new window.Event("resize"));
    expect(document.body.style.getPropertyValue("--environment-banner-height")).toBe("82px");
    height = 42;
    fireEvent(window, new window.Event("resize"));
    expect(document.body.style.getPropertyValue("--environment-banner-height")).toBe("42px");
    view.unmount();
    expect(document.body.style.getPropertyValue("--environment-banner-height")).toBe("42px");
  } finally {
    bounds.mockRestore();
    if (previous) document.body.style.setProperty("--environment-banner-height", previous);
    else document.body.style.removeProperty("--environment-banner-height");
  }
});
