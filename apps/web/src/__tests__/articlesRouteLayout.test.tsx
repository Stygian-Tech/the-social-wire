import LivePostLayout from "@/app/live-post/layout";
import LivestreamLayout from "@/app/livestream/layout";
import BrandAccountsLayout from "@/app/brand-accounts/layout";
import ContentCalendarLayout from "@/app/content-calendar/layout";
import AnalyticsLayout from "@/app/analytics/layout";
import * as Pro from "@/hooks/useProEntitlements";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as Navigation from "next/navigation";
import * as Auth from "@/hooks/useAuth";
import * as Sidebar from "@/components/AppSidebar/AppSidebar";
import * as PublicationContext from "@/contexts/PublicationSidebarContext";
import * as ReadContext from "@/contexts/ReadRouteContext";
import * as Workspace from "@/components/Articles/ArticlesWorkspace";
import ArticlesLayout from "@/app/articles/layout";
import ArticlesPage from "@/app/articles/page";
const replace = mock((path: string) => { void path; });
const push = mock((path: string) => { void path; });
const publication = "at://did:plc:author/site.standard.publication/news";
let loading: boolean;
let signedIn: boolean;
const restores: (() => void)[] = [];
const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
beforeAll(() => { Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) }); });
afterAll(() => { if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia); else Reflect.deleteProperty(window, "matchMedia"); });
let isPro = true;
beforeEach(() => {
  isPro = true;
  const access = spyOn(Pro, "useProEntitlements").mockImplementation(() => ({ isPro, isPending: false, isError: false, isFetching: false, refetch: async () => ({}) }) as ReturnType<typeof Pro.useProEntitlements>); restores.push(() => access.mockRestore());
  loading = false; signedIn = true; replace.mockClear(); push.mockClear();
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: signedIn ? { did: "did:plc:viewer" } : null, isLoading: loading } as ReturnType<typeof Auth.useAuth>));
  const router = spyOn(Navigation, "useRouter").mockReturnValue({ replace, push } as unknown as ReturnType<typeof Navigation.useRouter>);
  const publications = spyOn(PublicationContext, "PublicationSidebarProvider").mockImplementation(({ children }) => <>{children}</>);
  const read = spyOn(ReadContext, "ReadRouteProvider").mockImplementation(({ children }) => <>{children}</>);
  const sidebar = spyOn(Sidebar, "AppSidebar").mockImplementation(({ onSelectPub, showPublicationsRail }) => <aside aria-label="App Navigation" data-publications-rail={String(showPublicationsRail)}><button onClick={() => onSelectPub(publication)}>Open Publication</button></aside>);
  const workspace = spyOn(Workspace, "ArticlesWorkspace").mockImplementation(() => <section aria-label="Article Workspace">Private Draft Editor</section>);
  restores.push(...[auth, router, publications, read, sidebar, workspace].map(spy => () => spy.mockRestore()));
});
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });
async function show() { await act(async () => { render(<ArticlesLayout><ArticlesPage /></ArticlesLayout>); }); }
describe("Articles route", () => {
  it("waits for auth hydration before showing private drafts or redirecting", async () => {
    loading = true; signedIn = false;
    await show();
    expect(screen.getByRole("status").textContent).toBe("Loading Articles…");
    expect(screen.queryByRole("region", { name: "Article Workspace" })).toBeNull();
    expect(replace).not.toHaveBeenCalled();
  });
  it("redirects signed-out viewers without rendering the shell or workspace", async () => {
    signedIn = false;
    await show();
    expect(replace).toHaveBeenCalledWith("/login");
    expect(screen.queryByRole("complementary")).toBeNull();
    expect(screen.queryByText("Private Draft Editor")).toBeNull();
  });
  it("renders the signed-in workspace in the shared shell and preserves reader navigation", async () => {
    await show();
    expect(screen.getAllByRole("main").some(main => main.contains(screen.getByRole("region", { name: "Article Workspace" })))).toBe(true);
    expect(screen.getByRole("complementary", { name: "App Navigation" }).getAttribute("data-publications-rail")).toBe("false");
    expect(replace).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Open Publication" }));
    expect(push).toHaveBeenCalledWith(`/read/${encodeURIComponent(publication)}`);
  });
  it("shows the page loading fallback while its workspace suspends", async () => {
    let ready = false; let resolve!: () => void;
    const pending = new Promise<void>(done => { resolve = done; });
    const workspace = spyOn(Workspace, "ArticlesWorkspace").mockImplementation(() => { if (!ready) throw pending; return <p>Ready Editor</p>; }); restores.push(() => workspace.mockRestore());
    await show();
    expect(screen.getByRole("status").textContent).toBe("Loading Articles…");
    await act(async () => { ready = true; resolve(); await pending; });
    await waitFor(() => expect(screen.getByText("Ready Editor")).toBeTruthy());
  });
});

describe("Tools route access", () => {
  for (const [path, Layout] of [
    ["/articles", ArticlesLayout],
    ["/live-post", LivePostLayout],
    ["/livestream", LivestreamLayout],
    ["/brand-accounts", BrandAccountsLayout],
    ["/content-calendar", ContentCalendarLayout],
    ["/analytics", AnalyticsLayout],
  ] as const) {
    it(`denies direct ${path} access to Free viewers before mounting the workspace`, async () => {
      isPro = false;
      const workspace = mock(() => <p>Protected Workspace</p>);
      function ProtectedContent() { return workspace(); }
      await act(async () => { render(<Layout><ProtectedContent /></Layout>); });
      expect(screen.getByRole("heading", { name: "Social Wire Pro" })).toBeTruthy();
      expect(screen.getByText("Tools and multi-account support are available with Pro. Subscriptions are coming soon.")).toBeTruthy();
      expect(screen.queryByText("Protected Workspace")).toBeNull();
      expect(workspace).not.toHaveBeenCalled();
      expect(replace).not.toHaveBeenCalled();
    });
  }
});
