import { afterEach, expect, spyOn, test } from "bun:test";
import { cleanup, render } from "@testing-library/react";
import type { ReactNode } from "react";
import * as Navigation from "next/navigation";
import * as Mobile from "@/hooks/use-mobile";
import * as Auth from "@/hooks/useAuth";
import * as Sidebar from "@/components/AppSidebar/AppSidebar";
import * as Header from "@/components/Account/AccountHeader";
import * as Information from "@/components/Account/ProfileInformation";
import * as Content from "@/components/Account/ProfileContent";
import * as PublicationContext from "@/contexts/PublicationSidebarContext";
import * as ReaderContext from "@/contexts/ReadRouteContext";
import { attachFloatingGlassScrollOverlay } from "@/components/shared/floatingGlassScrollOverlay";
import MeLayout from "@/app/me/layout";
import AccountPage from "@/app/me/page";

const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).reverse().forEach(restore => restore()); });

test("account content uses the measured glass header viewport", () => {
  for (const name of ["HTMLElement", "Element", "ResizeObserver"] as const) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value: name === "ResizeObserver" ? class { observe() {} disconnect() {} } : window[name] });
    restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); });
  }
  const passthrough = ({ children }: { children: ReactNode }) => <>{children}</>;
  const spies = [
    spyOn(Mobile, "useIsMobile").mockReturnValue(false),
    spyOn(Navigation, "useRouter").mockReturnValue({ replace() {} } as unknown as ReturnType<typeof Navigation.useRouter>),
    spyOn(Auth, "useAuth").mockReturnValue({ session: { did: "did:plc:viewer" }, isLoading: false } as ReturnType<typeof Auth.useAuth>),
    spyOn(Sidebar, "AppSidebar").mockImplementation(() => <></>),
    spyOn(PublicationContext, "PublicationSidebarProvider").mockImplementation(passthrough),
    spyOn(ReaderContext, "ReadRouteProvider").mockImplementation(passthrough),
    spyOn(Header, "AccountHeader").mockImplementation(() => <header ref={surface => {
      if (!surface) return;
      surface.getBoundingClientRect = () => ({ height: 64 }) as DOMRect;
      return attachFloatingGlassScrollOverlay(surface, "top");
    }}>Your Profile</header>),
    spyOn(Information, "ProfileInformation").mockImplementation(() => <div>Profile Identity</div>),
    spyOn(Content, "ProfileContent").mockImplementation(() => <div>Profile Posts</div>),
  ];
  restores.push(...spies.map(spy => () => spy.mockRestore()));
  const view = render(<MeLayout><AccountPage /></MeLayout>);
  const shell = view.container.querySelector('[data-feed-header-shell]');
  const scroller = view.container.querySelector('[data-account-scroll]');
  expect(shell).not.toBeNull();
  expect(scroller?.closest('[data-feed-header-shell]')).toBe(shell);
  expect(shell?.getAttribute("data-floating-glass-shell-top")).toBe("true");
  expect((shell?.parentElement as HTMLElement).style.getPropertyValue("--floating-glass-top-extent")).toBe("64px");
  expect(scroller?.classList.contains("overflow-y-auto")).toBe(true);
});
