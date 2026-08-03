import { afterEach, describe, expect, it, mock } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";

mock.module("next/image", () => ({
  default: ({ alt, className }: { alt: string; className?: string }) => (
    // eslint-disable-next-line @next/next/no-img-element -- test double for next/image.
    <img alt={alt} className={className} />
  ),
}));

afterEach(cleanup);

describe("AppSidebarBrandHeader", () => {
  it("places the logo, unclipped title, and Beta on one row without sidebar actions", async () => {
    const { AppSidebarBrandHeader } = await import(
      "@/components/AppSidebar/AppSidebarBrandHeader"
    );
    const { container } = render(<AppSidebarBrandHeader />);

    const logo = container.querySelector("img");
    const title = screen.getByText("The Social Wire");
    const beta = screen.getByText("Beta");

    expect(logo?.parentElement?.className).toContain("gap-x-1.5");
    expect(logo?.className).toContain("row-start-1");
    expect(title.className).toContain("whitespace-nowrap");
    expect(title.className).not.toContain("truncate");
    expect(beta.className).toContain("col-start-3");
    expect(beta.className).not.toContain("row-start-2");
    expect(screen.queryByRole("button")).toBeNull();
  });
});
