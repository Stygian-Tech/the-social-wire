import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import * as Mobile from "@/hooks/use-mobile";
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar";
import {
  appMobileNavigationPaddingClasses,
  appViewportHeightClasses,
} from "@/components/shared/appViewportStyles";

let restoreMobile: (() => void) | undefined;
beforeEach(() => {
  const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false);
  restoreMobile = () => mobile.mockRestore();
});
afterEach(() => {
  cleanup();
  restoreMobile?.();
});

test("bounded account and reader panes reserve player space in every height constraint", () => {
  render(
    <SidebarProvider className={`overflow-hidden ${appViewportHeightClasses}`}>
      <SidebarInset className={`min-h-0 overflow-hidden ${appMobileNavigationPaddingClasses}`}>
        <main className="min-h-0 flex-1 overflow-y-auto"><button>Last Setting</button></main>
      </SidebarInset>
    </SidebarProvider>,
  );
  const shell = screen.getByRole("button", { name: "Last Setting" }).closest('[data-slot="sidebar-wrapper"]');
  for (const constraint of ["h", "min-h", "max-h"]) {
    expect(shell?.classList.contains(`${constraint}-[calc(100svh-var(--environment-banner-height,0px)-var(--podcast-player-height,0px))]`)).toBe(true);
  }
  expect(shell?.classList.contains("min-h-[calc(100svh-var(--environment-banner-height,0px))]")).toBe(false);
  const inset = shell?.querySelector('[data-slot="sidebar-inset"]');
  // The observer includes mobile navigation in occupancy, so only the remainder is padded.
  expect(inset?.classList.contains("pb-[max(0px,calc(4rem+env(safe-area-inset-bottom)-var(--podcast-player-height,0px)))]")).toBe(true);
  expect(inset?.classList.contains("pb-16")).toBe(false);
  expect(inset?.classList.contains("md:pb-0")).toBe(true);
});
