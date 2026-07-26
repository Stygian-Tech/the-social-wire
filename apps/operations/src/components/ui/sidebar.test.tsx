import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, fireEvent, render, screen } from "@testing-library/react"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarInset,
  SidebarNavButton,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar"

afterEach(cleanup)

describe("Sidebar", () => {
  it("keeps the toggle footer inside the viewport-height flex layout", () => {
    render(
      <SidebarProvider>
        <Sidebar>
          <SidebarHeader>Title</SidebarHeader>
          <SidebarContent>Navigation</SidebarContent>
          <SidebarFooter>
            <SidebarTrigger />
          </SidebarFooter>
        </Sidebar>
        <SidebarInset>Content</SidebarInset>
      </SidebarProvider>,
    )

    const aside = screen.getByRole("complementary")
    const toggle = screen.getByRole("button", { name: "Collapse Sidebar" })
    expect(aside.className).toContain("h-[calc(100svh-var(--operations-banner-height,0rem))]")
    expect(aside.className).toContain("flex-col")
    expect(toggle.parentElement?.className).toContain("shrink-0")
    expect(toggle.parentElement?.className).not.toContain("absolute")
    expect(screen.getByText("Title").className).toContain("h-[53.5px]")
    expect(aside.parentElement?.className).toContain("overflow-hidden")
    expect(aside.parentElement?.className).toContain("h-[calc(100svh-var(--operations-banner-height,0rem))]")
    expect(screen.getByRole("main").className).toContain("overflow-y-auto")
    expect(screen.getByRole("main").className).toContain("overscroll-contain")
  })

  it("shows navigation titles on hover when collapsed", () => {
    render(
      <SidebarProvider>
        <Sidebar>
          <SidebarContent>
            <SidebarNavButton icon={<span>O</span>}>Overview</SidebarNavButton>
          </SidebarContent>
          <SidebarFooter>
            <SidebarTrigger />
          </SidebarFooter>
        </Sidebar>
      </SidebarProvider>,
    )

    fireEvent.click(screen.getByRole("button", { name: "Collapse Sidebar" }))
    const navigationButton = screen.getByRole("button", { name: "Overview" })
    fireEvent.mouseEnter(navigationButton)

    expect(screen.getByRole("tooltip").textContent).toBe("Overview")
    expect(screen.getByRole("tooltip").getAttribute("data-placement")).toBe("right")
  })
})
