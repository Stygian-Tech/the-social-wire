import { afterEach, beforeAll, describe, expect, it } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import { Bookmark } from "lucide-react";

import { ReadLaterSidebarBadge } from "@/components/AppSidebar/ReadLaterSidebarBadge";
import { readLaterSidebarButtonClassName } from "@/components/AppSidebar/readLaterSidebarButtonStyles";
import {
  SidebarMenuButton,
  SidebarProvider,
} from "@/components/ui/sidebar";

describe("readLaterSidebarButtonClassName", () => {
  beforeAll(() => {
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({
        matches: false,
        addEventListener: () => undefined,
        removeEventListener: () => undefined,
      }),
    });
  });

  afterEach(cleanup);

  it("lets a Semble collection row grow when its name wraps", () => {
    const collectionName = "Things I Think Are Neat";

    render(
      <SidebarProvider>
        <SidebarMenuButton
          className={readLaterSidebarButtonClassName({
            usingSemble: true,
            count: 71,
          })}
        >
          <Bookmark />
          <span>{collectionName}</span>
          <ReadLaterSidebarBadge count={71} />
        </SidebarMenuButton>
      </SidebarProvider>,
    );

    const button = screen.getByText(collectionName).closest("button");
    expect(button).not.toBeNull();
    expect(button?.className).toContain("h-auto");
    expect(button?.className).toContain("min-h-[30px]");
    expect(button?.className).toContain("[&>span]:whitespace-normal!");
    expect(button?.className).toContain("relative");
    expect(button?.className).toContain("pr-8");
    expect(
      readLaterSidebarButtonClassName({ usingSemble: true, count: 0 }),
    ).toContain("[&>span]:whitespace-normal!");
  });

  it("keeps the existing fixed-height treatment for L@tr rows", () => {
    expect(
      readLaterSidebarButtonClassName({ usingSemble: false, count: 3 }),
    ).toBe("relative pr-8");
    expect(
      readLaterSidebarButtonClassName({ usingSemble: false, count: 0 }),
    ).toBeUndefined();
  });
});
