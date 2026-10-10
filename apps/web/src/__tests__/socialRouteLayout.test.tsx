import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as Navigation from "next/navigation";

import * as Auth from "@/hooks/useAuth";
import * as Sidebar from "@/components/AppSidebar/AppSidebar";
import * as PublicationContext from "@/contexts/PublicationSidebarContext";
import * as ReadContext from "@/contexts/ReadRouteContext";
import * as SocialFeeds from "@/components/Social/SocialFeeds";
import SocialLayout from "@/app/social/layout";

const replace = mock((path: string) => { void path; });
const push = mock((path: string) => { void path; });
const publication = "at://did:plc:author/site.standard.publication/news";
let loading: boolean;
let signedIn: boolean;
const restores: (() => void)[] = [];
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => { Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) }); });
afterAll(() => {
  if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia);
  else Reflect.deleteProperty(window, "matchMedia");
});
beforeEach(() => {
  loading = false;
  signedIn = true;
  replace.mockClear();
  push.mockClear();
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: signedIn ? { did: "did:plc:viewer" } : null, isLoading: loading } as ReturnType<typeof Auth.useAuth>));
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ replace, push } as unknown as ReturnType<typeof Navigation.useRouter>);
  const publications = spyOn(PublicationContext, "PublicationSidebarProvider").mockImplementation(({ children }) => <>{children}</>);
  const read = spyOn(ReadContext, "ReadRouteProvider").mockImplementation(({ children }) => <>{children}</>);
  const sidebar = spyOn(Sidebar, "AppSidebar").mockImplementation(({ onSelectPub, showPublicationsRail }) => <aside data-publications-rail={String(showPublicationsRail)}><button onClick={() => onSelectPub(publication)}>Open Publication</button></aside>);
  const feeds = spyOn(SocialFeeds, "SocialFeeds").mockImplementation(() => <nav aria-label="Social Feeds">Following</nav>);
  restores.push(...[auth, router, publications, read, sidebar, feeds].map(spy => () => spy.mockRestore()));
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
async function show() {
  let view!: ReturnType<typeof render>;
  await act(async () => { view = render(<SocialLayout><p>Social Content</p></SocialLayout>); });
  return view;
}

describe("Social route layout", () => {
  it("waits for auth hydration without displaying content or redirecting", async () => {
    loading = true;
    signedIn = false;
    const view = await show();
    expect(screen.queryByText("Social Content")).toBeNull();
    expect(view.container.querySelector(".animate-spin")).toBeTruthy();
    expect(replace).not.toHaveBeenCalled();
  });

  it("redirects signed-out viewers and hides the signed-in shell", async () => {
    signedIn = false;
    await show();
    expect(replace).toHaveBeenCalledWith("/login");
    expect(screen.queryByText("Social Content")).toBeNull();
    expect(screen.queryByRole("complementary")).toBeNull();
  });

  it("renders authenticated content without a publication rail and keeps reader navigation available", async () => {
    await show();
    expect(screen.getByText("Social Content")).toBeTruthy();
    expect(screen.getAllByRole("complementary").find(item => item.hasAttribute("data-publications-rail"))?.getAttribute("data-publications-rail")).toBe("false");
    expect(screen.getByRole("complementary", { name: "Social Feed Sidebar" }).contains(screen.getByRole("navigation", { name: "Social Feeds" }))).toBe(true);
    expect(replace).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Open Publication" }));
    expect(push).toHaveBeenCalledWith(`/read/${encodeURIComponent(publication)}`);
  });
});
