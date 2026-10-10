import { afterAll, afterEach, beforeAll, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { SidebarSocialSection } from "@/components/AppSidebar/SidebarSocialSection";
import { SidebarProvider } from "@/components/ui/sidebar";
import * as catalogHooks from "@/hooks/useBlueskySocialCatalog";
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => {
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
});
afterAll(() => {
  if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
});
afterEach(cleanup);
async function renderSection(overrides: Partial<React.ComponentProps<typeof SidebarSocialSection>> = {}) {
  const onHome = mock(() => undefined);
  await act(async () => { render(<SidebarProvider><SidebarSocialSection active={false} onHome={onHome} {...overrides} /></SidebarProvider>); });
  return { onHome };
}
describe("SidebarSocialSection", () => {
  it("shows enabled destinations without expansion controls or settings", async () => {
    const onNavigate = mock((href: string) => { void href; });
    const { onHome } = await renderSection({ active: true, activeSection: "bookmarks", onNavigate });
    for (const name of ["Home", "Explore", "Notifications", "Messages", "Bookmarks", "Lists", "Feeds"]) {
      const button = screen.getByRole("button", { name: `Social ${name}` }) as HTMLButtonElement;
      expect(button.disabled).toBe(false);
      expect(button.querySelector("[data-coming-soon]")).toBeNull();
    }
    expect(screen.getByRole("button", { name: "Social Bookmarks" }).getAttribute("aria-current")).toBe("page");
    expect(screen.getByRole("button", { name: "Social Home" }).getAttribute("aria-current")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Social Home" }));
    expect(onHome).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "Social Bookmarks" }));
    expect(onNavigate).toHaveBeenLastCalledWith("/social/bookmarks");
    fireEvent.click(screen.getByRole("button", { name: "Social Explore" }));
    expect(onNavigate).toHaveBeenLastCalledWith("/social/explore");
    expect(screen.queryByText("Profile")).toBeNull();
    expect(screen.queryByText("Settings")).toBeNull();
    expect(screen.queryByRole("button", { name: /Expand Social|Collapse Social/ })).toBeNull();
  });
  it("keeps Social inactive outside Social without loading the feed catalog", async () => {
    const catalog = spyOn(catalogHooks, "useBlueskySocialCatalog");
    try {
      await renderSection({ active: false });
      expect(screen.getAllByRole("button")).toHaveLength(7);
      for (const button of screen.getAllByRole("button")) expect(button.getAttribute("aria-current")).toBeNull();
      expect(catalog).not.toHaveBeenCalled();
    } finally { catalog.mockRestore(); }
  });
});
