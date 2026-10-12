import * as Pro from "@/hooks/useProEntitlements";
import { afterAll, afterEach, beforeAll, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { SidebarToolsSection } from "@/components/AppSidebar/SidebarToolsSection";
import { SidebarProvider } from "@/components/ui/sidebar";

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => { Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) }); });
afterAll(() => { if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia); else Reflect.deleteProperty(window, "matchMedia"); });
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
it("groups all tool workspaces and navigates to the selected destination", async () => {
  const entitlement = spyOn(Pro, "useProEntitlements").mockReturnValue({ isPro: true } as ReturnType<typeof Pro.useProEntitlements>); restores.push(() => entitlement.mockRestore());
  const onNavigate = mock(() => {});
  await act(async () => { render(<SidebarProvider><SidebarToolsSection pathname="/livestream" onNavigate={onNavigate} /></SidebarProvider>); });
  for (const title of ["Articles", "Live Post", "Livestream", "Brand Accounts", "Content Calendar", "Analytics"]) expect(screen.getByRole("button", { name: title })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Livestream" }).getAttribute("aria-current")).toBe("page");
  expect(screen.getByRole("button", { name: "Analytics" }).getAttribute("aria-current")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Analytics" }));
  expect(onNavigate).toHaveBeenCalledWith("/analytics");
});

it("marks every Tools destination as locked for Free viewers while keeping its gate reachable", async () => {
  const entitlement = spyOn(Pro, "useProEntitlements").mockReturnValue({ isPro: false } as ReturnType<typeof Pro.useProEntitlements>); restores.push(() => entitlement.mockRestore());
  const onNavigate = mock(() => {});
  await act(async () => { render(<SidebarProvider><SidebarToolsSection pathname="/social" onNavigate={onNavigate} /></SidebarProvider>); });
  expect(screen.getByText("Pro")).toBeTruthy();
  for (const title of ["Articles", "Live Post", "Livestream", "Brand Accounts", "Content Calendar", "Analytics"]) {
    const destination = screen.getByRole("button", { name: title });
    expect(destination.querySelector("svg.lucide-lock-keyhole")).toBeTruthy();
  }
  fireEvent.click(screen.getByRole("button", { name: "Analytics" }));
  expect(onNavigate).toHaveBeenCalledWith("/analytics");
});
