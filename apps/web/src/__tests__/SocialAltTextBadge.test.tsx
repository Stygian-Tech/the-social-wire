import { afterAll, afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { SocialAltTextBadge } from "@/components/Social/SocialAltTextBadge";

const browserGlobals = [
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
] as const;
const originalBrowserGlobals = browserGlobals.map(
  (name) => [name, Object.getOwnPropertyDescriptor(globalThis, name)] as const,
);
beforeAll(() => {
  Object.defineProperty(globalThis, "requestAnimationFrame", {
    configurable: true,
    value: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(performance.now()), 0),
  });
  Object.defineProperty(globalThis, "cancelAnimationFrame", {
    configurable: true,
    value: (handle: ReturnType<typeof setTimeout>) => clearTimeout(handle),
  });
  Object.defineProperty(globalThis, "getComputedStyle", {
    configurable: true,
    value: window.getComputedStyle.bind(window),
  });
});
afterAll(async () => {
  await new Promise((resolve) => setTimeout(resolve, 10));
  for (const [name, descriptor] of originalBrowserGlobals) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else Reflect.deleteProperty(globalThis, name);
  }
});

afterEach(cleanup);

describe("Social Alt Text Badge", () => {
  it.each(["", " ", "\n\t "])("omits a badge for blank text %j", (alt) => {
    const { container } = render(<SocialAltTextBadge alt={alt} />);
    expect(container.childElementCount).toBe(0);
    expect(screen.queryByRole("button")).toBeNull();
  });
  it("opens the complete multiline description as safe plain text", async () => {
    const alt = `<script>alert('fixture')</script>\n<img src=x onerror=alert(1)>\n${"Long description 🌿 ".repeat(200)}`;
    render(<SocialAltTextBadge alt={alt} />);
    fireEvent.click(screen.getByRole("button", { name: "View Alt Text" }));
    const dialog = await screen.findByRole("dialog", { name: "Alt Text" });
    const description = within(dialog).getByText(alt, { exact: true, normalizer: value => value });
    expect(description.textContent).toBe(alt);
    expect(description.className).toContain("whitespace-pre-wrap");
    expect(description.className).toContain("overflow-y-auto");
    expect(dialog.querySelector("script, img")).toBeNull();
  });
  it("uses the supplied accessible label and opens without activating a parent", async () => {
    const parentClick = mock(() => undefined);
    render(<div onClick={parentClick}><SocialAltTextBadge alt="Author description" label="View Image 2 Alt Text" /></div>);
    fireEvent.click(screen.getByRole("button", { name: "View Image 2 Alt Text" }));
    const dialog = await screen.findByRole("dialog", { name: "Alt Text" });
    expect(within(dialog).getByText("Author description")).toBeTruthy();
    expect(parentClick).not.toHaveBeenCalled();
    fireEvent.click(within(dialog).getByRole("button", { name: "Close" }));
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    fireEvent.click(screen.getByRole("button", { name: "View Image 2 Alt Text" }));
    expect(await screen.findByRole("dialog", { name: "Alt Text" })).toBeTruthy();
  });
});
