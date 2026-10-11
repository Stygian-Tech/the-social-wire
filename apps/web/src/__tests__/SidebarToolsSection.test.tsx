import { afterAll, afterEach, beforeAll, expect, it, mock } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { SidebarToolsSection } from "@/components/AppSidebar/SidebarToolsSection";
import { SidebarProvider } from "@/components/ui/sidebar";

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => { Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) }); });
afterAll(() => { if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia); else Reflect.deleteProperty(window, "matchMedia"); });
afterEach(cleanup);
it("groups all tool workspaces and navigates to the selected destination", async () => {
  const onNavigate = mock(() => {});
  await act(async () => { render(<SidebarProvider><SidebarToolsSection pathname="/livestream" onNavigate={onNavigate} /></SidebarProvider>); });
  for (const title of ["Articles", "Live Post", "Livestream", "Brand Accounts", "Content Calendar", "Analytics"]) expect(screen.getByRole("button", { name: title })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Livestream" }).getAttribute("aria-current")).toBe("page");
  expect(screen.getByRole("button", { name: "Analytics" }).getAttribute("aria-current")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Analytics" }));
  expect(onNavigate).toHaveBeenCalledWith("/analytics");
});
