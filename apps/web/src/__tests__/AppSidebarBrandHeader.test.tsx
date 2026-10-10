import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import * as NextImage from "next/image";
import type { ImageProps } from "next/image";

describe("AppSidebarBrandHeader", () => {
  let restoreImageSpy: (() => void) | undefined;

  beforeEach(() => {
    const imageFixture = (({ alt, className }: ImageProps) => (
      // eslint-disable-next-line @next/next/no-img-element -- scoped test double for next/image.
      <img alt={alt} className={className} />
    )) as typeof NextImage.default;
    const imageSpy = spyOn(NextImage, "default").mockImplementation(imageFixture);
    restoreImageSpy = () => imageSpy.mockRestore();
  });

  afterEach(() => {
    cleanup();
    restoreImageSpy?.();
    restoreImageSpy = undefined;
  });

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
