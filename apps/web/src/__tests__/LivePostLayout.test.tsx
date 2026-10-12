import * as Pro from "@/hooks/useProEntitlements";
import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as Auth from "@/hooks/useAuth";
import * as Mobile from "@/hooks/use-mobile";
import * as Navigation from "next/navigation";
import * as Sidebar from "@/components/AppSidebar/AppSidebar";
import * as Publications from "@/contexts/PublicationSidebarContext";
import * as Reader from "@/contexts/ReadRouteContext";
import LivePostLayout from "@/app/live-post/layout";

const restores: (() => void)[] = [];
let authState: ReturnType<typeof Auth.useAuth>;
const replace = mock(() => {});
const push = mock(() => {});
let isPro = true;
beforeEach(() => {
  isPro = true;
  const access = spyOn(Pro, "useProEntitlements").mockImplementation(() => ({ isPro, isPending: false, isError: false, isFetching: false, refetch: async () => ({}) }) as ReturnType<typeof Pro.useProEntitlements>); restores.push(() => access.mockRestore());
  replace.mockClear(); push.mockClear();
  authState = { session: null, isLoading: false } as ReturnType<typeof Auth.useAuth>;
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => authState);
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ push, replace } as unknown as ReturnType<typeof Navigation.useRouter>);
  const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false);
  restores.push(() => auth.mockRestore(), () => router.mockRestore(), () => mobile.mockRestore());
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

test("waits for account restoration before redirecting signed-out visitors", async () => {
  authState = { session: null, isLoading: true } as ReturnType<typeof Auth.useAuth>;
  const { rerender } = render(<LivePostLayout><p>Workspace Content</p></LivePostLayout>);
  expect(screen.getByRole("status").textContent).toBe("Loading Live Post…");
  expect(replace).not.toHaveBeenCalled();
  expect(screen.queryByText("Workspace Content")).toBeNull();
  authState = { session: null, isLoading: false } as ReturnType<typeof Auth.useAuth>;
  await act(async () => { rerender(<LivePostLayout><p>Workspace Content</p></LivePostLayout>); });
  expect(replace).toHaveBeenCalledWith("/login");
  expect(screen.queryByText("Workspace Content")).toBeNull();
});

test("uses the shared bounded sidebar shell for an authenticated workspace and retains reader navigation", async () => {
  authState = { session: { did: "did:plc:alice" }, isLoading: false } as ReturnType<typeof Auth.useAuth>;
  const publications = spyOn(Publications, "PublicationSidebarProvider").mockImplementation(({ children }) => <div data-testid="publication-provider">{children}</div>);
  const reader = spyOn(Reader, "ReadRouteProvider").mockImplementation(({ children }) => <div data-testid="read-provider">{children}</div>);
  const sidebar = spyOn(Sidebar, "AppSidebar").mockImplementation(({ showPublicationsRail, onSelectPub }) => <nav aria-label="Test Sidebar" data-rail={String(showPublicationsRail)}><button onClick={() => onSelectPub?.("at://did:plc:alice/site.standard.publication/p")}>Open Publication</button></nav>);
  restores.push(() => publications.mockRestore(), () => reader.mockRestore(), () => sidebar.mockRestore());
  await act(async () => { render(<LivePostLayout><p>Workspace Content</p></LivePostLayout>); });
  expect(screen.getByRole("navigation", { name: "Test Sidebar" }).getAttribute("data-rail")).toBe("false");
  const content = screen.getByText("Workspace Content");
  expect(content.closest('[data-slot="sidebar-inset"]')).not.toBeNull();
  expect(content.closest('[data-slot="sidebar-wrapper"]')?.className).toContain("overflow-hidden");
  expect(screen.getByTestId("publication-provider").contains(content)).toBe(true);
  expect(screen.getByTestId("read-provider").contains(content)).toBe(true);
  expect(replace).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Open Publication" }));
  expect(push).toHaveBeenCalledWith("/read/at%3A%2F%2Fdid%3Aplc%3Aalice%2Fsite.standard.publication%2Fp");
});
