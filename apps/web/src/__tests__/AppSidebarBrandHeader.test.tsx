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
  it("places the logo and unclipped title on one row without status badges or actions", async () => {
    const { AppSidebarBrandHeader } = await import(
      "@/components/AppSidebar/AppSidebarBrandHeader"
    );
    const { container } = render(<AppSidebarBrandHeader />);

    const logo = container.querySelector("img");
    const title = screen.getByText("The Social Wire");

    expect(logo?.parentElement?.className).toContain("gap-x-1.5");
    expect(logo?.className).toContain("row-start-1");
    expect(title.className).toContain("whitespace-nowrap");
    expect(title.className).not.toContain("truncate");
    expect(screen.queryByText("Beta")).toBeNull();
    expect(screen.queryByRole("button")).toBeNull();
  });
});
