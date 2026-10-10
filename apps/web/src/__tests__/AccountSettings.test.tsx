import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import * as Auth from "@/hooks/useAuth";
import * as Profile from "@/hooks/useViewerProfile";
import * as FeedSettings from "@/components/Account/FeedSettingsSection";
import * as ImportSettings from "@/components/Account/OpmlImportSection";
import * as Player from "@/components/Podcasts/PodcastPlayerProvider";
import * as Playback from "@/lib/podcasts/playback";
import * as Navigation from "next/navigation";
import { initialPodcastState } from "@/lib/podcasts/client";
import { AccountSettingsContent } from "@/components/Account/AccountSettingsContent";
import { AccountSettingsDialog } from "@/components/Account/AccountSettingsDialog";
import { AccountHeader } from "@/components/Account/AccountHeader";
import { SidebarProvider } from "@/components/ui/sidebar";
import SettingsPage from "@/app/me/settings/page";

const restoreGlobals: (() => void)[] = [];
const signOut = mock(async () => {});
const changeState = mock(async () => {});
const setRemoveSilences = mock(async () => {});

beforeEach(() => {
  window.history.replaceState(null, "", "/me");
  const mediaDescriptor = Object.getOwnPropertyDescriptor(window, "matchMedia");
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
  restoreGlobals.push(() => { if (mediaDescriptor) Object.defineProperty(window, "matchMedia", mediaDescriptor); else Reflect.deleteProperty(window, "matchMedia"); });
  for (const [name, value] of Object.entries({ HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, DOMRect: window.DOMRect, getComputedStyle: window.getComputedStyle.bind(window), requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restoreGlobals.push(() => { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else Reflect.deleteProperty(globalThis, name); });
  }
  signOut.mockReset().mockImplementation(async () => {});
  changeState.mockClear();
  setRemoveSilences.mockClear();
  spyOn(Auth, "useAuth").mockReturnValue({ session: { did: "did:plc:settings-viewer" }, signOut, isLoading: false, oauthSessionReloadSeq: 0, applyOAuthSession() {}, getOAuthSession: () => null, getAuthFetch: () => null, reconcileOAuthSession: async () => false, signIn: async () => {} });
  spyOn(Profile, "useViewerProfile").mockReturnValue({ data: { handle: "reader.test" } } as ReturnType<typeof Profile.useViewerProfile>);
  spyOn(FeedSettings, "FeedSettingsSection").mockImplementation(() => <section aria-label="Existing Feed Settings">Existing Preference Controls</section>);
  spyOn(ImportSettings, "OpmlImportSection").mockImplementation(() => <section aria-label="Existing OPML Import">Existing Import Controls</section>);
  spyOn(Playback, "podcastsEnabled").mockReturnValue(true);
  spyOn(Player, "useOptionalPodcastPlayer").mockReturnValue({ episode: null, playing: false, position: 0, duration: 0, state: initialPodcastState(), error: null, silence: null, play: async () => {}, toggle() {}, seek() {}, changeState, setRemoveSilences, clearError() {} });
  spyOn(Navigation, "usePathname").mockReturnValue("/me");
});

afterEach(() => {
  cleanup();
  window.history.replaceState(null, "", "/");
  mock.restore();
  for (const restore of restoreGlobals.splice(0).reverse()) restore();
});

test("settings route renders the existing preferences, import, account, and enabled podcast controls", () => {
  render(<SettingsPage />);
  expect(screen.getByText("@reader.test")).toBeTruthy();
  expect(screen.getByRole("region", { name: "Existing Feed Settings" })).toBeTruthy();
  expect(screen.getByRole("region", { name: "Existing OPML Import" })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Playback Defaults" })).toBeTruthy();
});

test("podcast defaults are hidden when the feature is disabled or the player is unavailable", () => {
  spyOn(Playback, "podcastsEnabled").mockReturnValue(false);
  const view = render(<AccountSettingsContent />);
  expect(screen.queryByRole("button", { name: "Playback Defaults" })).toBeNull();
  spyOn(Playback, "podcastsEnabled").mockReturnValue(true);
  spyOn(Player, "useOptionalPodcastPlayer").mockReturnValue(null);
  view.rerender(<AccountSettingsContent />);
  expect(screen.queryByRole("button", { name: "Playback Defaults" })).toBeNull();
});

test("profile cog opens accessible settings and Done closes it", async () => {
  render(<AccountSettingsDialog />);
  expect(screen.queryByText("Existing Preference Controls")).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Settings" }));
  const dialog = await screen.findByRole("dialog", { name: "Settings" });
  expect(within(dialog).getByText("Existing Import Controls")).toBeTruthy();
  fireEvent.click(within(dialog).getByRole("button", { name: "Done" }));
  await waitFor(() => expect(screen.queryByRole("dialog", { name: "Settings" })).toBeNull());
});

test("profile header keeps the profile title and its cog opens the real settings modal", async () => {
  render(<SidebarProvider><AccountHeader /></SidebarProvider>);
  expect(screen.getByRole("heading", { name: "Your Profile", level: 1 })).toBeTruthy();
  expect(screen.queryByRole("link", { name: "Back to Profile" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Settings" }));
  const dialog = await screen.findByRole("dialog", { name: "Settings" });
  expect(within(dialog).getByText("Existing Preference Controls")).toBeTruthy();
  fireEvent.click(within(dialog).getByRole("button", { name: "Done" }));
  await waitFor(() => expect(screen.queryByRole("dialog", { name: "Settings" })).toBeNull());
});

test("direct settings header offers a profile return link and restores the cog on the profile route", async () => {
  const pathname = spyOn(Navigation, "usePathname").mockReturnValue("/me/settings");
  const view = render(<SidebarProvider><AccountHeader /></SidebarProvider>);
  expect(screen.getByRole("heading", { name: "Settings", level: 1 })).toBeTruthy();
  expect(screen.getByRole("link", { name: "Back to Profile" }).getAttribute("href")).toBe("/me");
  expect(screen.queryByRole("button", { name: "Settings" })).toBeNull();
  pathname.mockReturnValue("/me");
  view.rerender(<SidebarProvider><AccountHeader /></SidebarProvider>);
  expect(screen.getByRole("heading", { name: "Your Profile", level: 1 })).toBeTruthy();
  expect(screen.getByRole("button", { name: "Settings" })).toBeTruthy();
  expect(screen.queryByRole("link", { name: "Back to Profile" })).toBeNull();
  await act(async () => {});
});

test("legacy settings hash opens the modal and Done clears the legacy anchor", async () => {
  window.history.replaceState(null, "", "/me#settings");
  render(<AccountSettingsDialog />);
  const dialog = await screen.findByRole("dialog", { name: "Settings" });
  fireEvent.click(within(dialog).getByRole("button", { name: "Done" }));
  await waitFor(() => expect(screen.queryByRole("dialog", { name: "Settings" })).toBeNull());
  expect(window.location.hash).toBe("");
});

test("read-history and import legacy hash changes open settings on the profile", async () => {
  render(<AccountSettingsDialog />);
  for (const hash of ["read-history", "opml-import"]) {
    window.history.replaceState(null, "", `/me#${hash}`);
    act(() => { window.dispatchEvent(new window.HashChangeEvent("hashchange")); });
    const dialog = await screen.findByRole("dialog", { name: "Settings" });
    fireEvent.click(within(dialog).getByRole("button", { name: "Done" }));
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Settings" })).toBeNull());
  }
});

test("logout requires confirmation and Cancel keeps the account signed in", async () => {
  render(<AccountSettingsContent />);
  fireEvent.click(screen.getByRole("button", { name: "Log Out" }));
  const confirmation = await screen.findByRole("dialog", { name: "Log Out of The Social Wire?" });
  expect(signOut).not.toHaveBeenCalled();
  fireEvent.click(within(confirmation).getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  expect(signOut).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Log Out" }));
  const reopened = await screen.findByRole("dialog", { name: "Log Out of The Social Wire?" });
  fireEvent.click(within(reopened).getByRole("button", { name: "Log Out" }));
  await waitFor(() => expect(signOut).toHaveBeenCalledTimes(1));
  await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
});

test("logout confirmation works inside the settings modal without closing the parent", async () => {
  render(<AccountSettingsDialog />);
  fireEvent.click(screen.getByRole("button", { name: "Settings" }));
  const settings = await screen.findByRole("dialog", { name: "Settings" });
  fireEvent.click(within(settings).getByRole("button", { name: "Log Out" }));
  const confirmation = await screen.findByRole("dialog", { name: "Log Out of The Social Wire?" });
  fireEvent.click(within(confirmation).getByRole("button", { name: "Cancel" }));
  await waitFor(() => expect(screen.queryByRole("dialog", { name: "Log Out of The Social Wire?" })).toBeNull());
  expect(screen.getByRole("dialog", { name: "Settings" })).toBeTruthy();
  expect(signOut).not.toHaveBeenCalled();
});

test("logout failure remains visible and permits retry", async () => {
  signOut.mockImplementationOnce(async () => { throw new Error("Session revocation failed."); });
  render(<AccountSettingsContent />);
  fireEvent.click(screen.getByRole("button", { name: "Log Out" }));
  const confirmation = await screen.findByRole("dialog", { name: "Log Out of The Social Wire?" });
  fireEvent.click(within(confirmation).getByRole("button", { name: "Log Out" }));
  await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("Session revocation failed."));
  fireEvent.click(within(confirmation).getByRole("button", { name: "Log Out" }));
  await waitFor(() => expect(signOut).toHaveBeenCalledTimes(2));
});

test("podcast settings reuse the player mutation handlers", async () => {
  render(<AccountSettingsContent />);
  fireEvent.click(screen.getByRole("button", { name: "Playback Defaults" }));
  await screen.findByRole("dialog", { name: "Playback Defaults" });
  fireEvent.change(screen.getByRole("combobox", { name: "Default Speed" }), { target: { value: "1.5" } });
  expect(changeState).toHaveBeenCalledWith({ playbackSpeed: 1.5 });
  fireEvent.click(screen.getByRole("checkbox", { name: "Remove Silences by Default" }));
  expect(setRemoveSilences).toHaveBeenCalledWith(true);
});
