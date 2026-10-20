import { afterAll, afterEach, beforeAll, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { SidebarSocialSection } from "@/components/AppSidebar/SidebarSocialSection";
import { SidebarProvider } from "@/components/ui/sidebar";
import * as catalogHooks from "@/hooks/useBlueskySocialCatalog";
import { SOCIAL_HOME_REFRESH_EVENT } from "@/lib/socialHomeRefresh";
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
  it("requests a refresh only when Home is double-clicked while selected", async () => {
    const refresh = mock(() => {});
    window.addEventListener(SOCIAL_HOME_REFRESH_EVENT, refresh);
    try {
      await renderSection({ active: true });
      const home = screen.getByRole("button", { name: "Social Home" });
      fireEvent.click(home);
      expect(refresh).not.toHaveBeenCalled();
      fireEvent.doubleClick(home);
      expect(refresh).toHaveBeenCalledTimes(1);
      cleanup();
      await renderSection({ active: false });
      fireEvent.doubleClick(screen.getByRole("button", { name: "Social Home" }));
      expect(refresh).toHaveBeenCalledTimes(1);
    } finally { window.removeEventListener(SOCIAL_HOME_REFRESH_EVENT, refresh); }
  });
  it("shows enabled destinations without expansion controls or settings", async () => {
    const onNavigate = mock((href: string) => { void href; });
    const { onHome } = await renderSection({ active: true, activeSection: "bookmarks", onNavigate });
    for (const name of ["Home", "Explore", "Notifications", "Messages", "Bookmarks", "Drafts", "Lists", "Feeds"]) {
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
  it("navigates to Drafts and marks it as the active destination", async () => {
    const onNavigate = mock((href: string) => { void href; });
    await renderSection({ active: true, activeSection: "drafts", onNavigate });
    const drafts = screen.getByRole("button", { name: "Social Drafts" });
    expect(drafts.getAttribute("aria-current")).toBe("page");
    fireEvent.click(drafts);
    expect(onNavigate).toHaveBeenCalledWith("/social/drafts");
  });
  it("shows shared unread counters on Notifications and Messages and hides zero counts", async () => {
    const { onHome } = await renderSection({ notificationCount: 123, messageCount: 7 });
    expect(screen.getByRole("button", { name: "Social Notifications" }).parentElement!.querySelector('[aria-label="123 unread"]')?.textContent).toBe("123");
    expect(screen.getByRole("button", { name: "Social Messages" }).parentElement!.querySelector('[aria-label="7 unread"]')?.textContent).toBe("7");
    expect(screen.getByRole("button", { name: "Social Home" }).querySelector('[aria-label$="unread"]')).toBeNull();
    cleanup();
    await renderSection({ onHome });
    expect(screen.queryByLabelText(/unread$/)).toBeNull();
  });
  it("keeps Social inactive outside Social without loading the feed catalog", async () => {
    const catalog = spyOn(catalogHooks, "useBlueskySocialCatalog");
    try {
      await renderSection({ active: false });
      expect(screen.getAllByRole("button")).toHaveLength(8);
      for (const button of screen.getAllByRole("button")) expect(button.getAttribute("aria-current")).toBeNull();
      expect(catalog).not.toHaveBeenCalled();
    } finally { catalog.mockRestore(); }
  });
});
