import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";

import { AppearanceSettingsSection } from "@/components/Account/AppearanceSettingsSection";
import { AppearanceProvider } from "@/hooks/useAppearance";
import {
  BOLD_TEXT_STORAGE_KEY,
  FONT_STORAGE_KEY,
  THEME_STORAGE_KEY,
} from "@/lib/appearance";

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
const systemThemeListeners = new Set<() => void>();
let systemDark = false;

function setSystemDark(dark: boolean) {
  act(() => {
    systemDark = dark;
    systemThemeListeners.forEach((listener) => listener());
  });
}

beforeEach(() => {
  systemDark = false;
  systemThemeListeners.clear();
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: (query: string) => ({
      get matches() {
        return query === "(prefers-color-scheme: dark)" && systemDark;
      },
      addEventListener: (event: string, listener: () => void) => {
        if (event === "change") systemThemeListeners.add(listener);
      },
      removeEventListener: (event: string, listener: () => void) => {
        if (event === "change") systemThemeListeners.delete(listener);
      },
    }),
  });
  window.localStorage.removeItem(THEME_STORAGE_KEY);
  window.localStorage.removeItem(FONT_STORAGE_KEY);
  window.localStorage.removeItem(BOLD_TEXT_STORAGE_KEY);
});

afterEach(() => {
  cleanup();
  expect(systemThemeListeners.size).toBe(0);
  if (originalMatchMedia) {
    Object.defineProperty(window, "matchMedia", originalMatchMedia);
  } else {
    Reflect.deleteProperty(window, "matchMedia");
  }
  document.documentElement.classList.remove("dark", "light");
  delete document.documentElement.dataset.theme;
  delete document.documentElement.dataset.computedTheme;
  delete document.documentElement.dataset.font;
  delete document.documentElement.dataset.boldText;
  document.documentElement.style.removeProperty("color-scheme");
});

describe("AppearanceSettingsSection", () => {
  it("initially follows a dark system preference without a stored override", () => {
    systemDark = true;
    render(<AppearanceProvider><AppearanceSettingsSection /></AppearanceProvider>);

    expect(screen.getByRole("radio", { name: "System" }).getAttribute("aria-checked")).toBe("true");
    expect(screen.getByText("System (Dark)")).toBeTruthy();
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(document.documentElement.classList.contains("light")).toBe(false);
    expect(document.documentElement.dataset.theme).toBe("system");
    expect(document.documentElement.dataset.computedTheme).toBe("dark");
    expect(document.documentElement.style.colorScheme).toBe("dark");
    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBeNull();
  });

  it("follows live system dark and light changes", () => {
    render(<AppearanceProvider><AppearanceSettingsSection /></AppearanceProvider>);

    setSystemDark(true);
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(screen.getByText("System (Dark)")).toBeTruthy();
    expect(document.documentElement.style.colorScheme).toBe("dark");

    setSystemDark(false);
    expect(document.documentElement.classList.contains("dark")).toBe(false);
    expect(document.documentElement.classList.contains("light")).toBe(true);
    expect(screen.getByText("System (Light)")).toBeTruthy();
    expect(document.documentElement.style.colorScheme).toBe("light");
  });

  it("preserves an explicit Light override during system changes", () => {
    window.localStorage.setItem(THEME_STORAGE_KEY, "light");
    systemDark = true;
    render(<AppearanceProvider><AppearanceSettingsSection /></AppearanceProvider>);

    setSystemDark(false);
    setSystemDark(true);

    expect(screen.getByRole("radio", { name: "Light" }).getAttribute("aria-checked")).toBe("true");
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);
    expect(document.documentElement.style.colorScheme).toBe("light");
    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBe("light");
  });

  it("removes the Light override and applies dark when System is selected", () => {
    window.localStorage.setItem(THEME_STORAGE_KEY, "light");
    systemDark = true;
    render(<AppearanceProvider><AppearanceSettingsSection /></AppearanceProvider>);

    fireEvent.click(screen.getByRole("radio", { name: "System" }));

    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBeNull();
    expect(document.documentElement.dataset.theme).toBe("system");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(document.documentElement.style.colorScheme).toBe("dark");
    expect(screen.getByText("System (Dark)")).toBeTruthy();
  });

  it("reconciles an appearance change from another browser tab", () => {
    systemDark = true;
    render(<AppearanceProvider><AppearanceSettingsSection /></AppearanceProvider>);

    act(() => {
      window.localStorage.setItem(THEME_STORAGE_KEY, "light");
      window.dispatchEvent(new window.StorageEvent("storage", { key: THEME_STORAGE_KEY, newValue: "light" }));
    });
    expect(document.documentElement.dataset.theme).toBe("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);

    act(() => {
      window.localStorage.removeItem(THEME_STORAGE_KEY);
      window.dispatchEvent(new window.StorageEvent("storage", { key: THEME_STORAGE_KEY, oldValue: "light", newValue: null }));
    });
    expect(document.documentElement.dataset.theme).toBe("system");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(screen.getByText("System (Dark)")).toBeTruthy();
  });

  it("applies and persists theme, font, and bold text choices", () => {
    render(
      <AppearanceProvider>
        <AppearanceSettingsSection />
      </AppearanceProvider>,
    );

    fireEvent.click(screen.getByRole("radio", { name: "Dark" }));
    fireEvent.click(screen.getByRole("radio", { name: "Serif" }));
    fireEvent.click(screen.getByRole("button", { name: /Bold Text/ }));

    expect(window.localStorage.getItem(THEME_STORAGE_KEY)).toBe("dark");
    expect(window.localStorage.getItem(FONT_STORAGE_KEY)).toBe("serif");
    expect(window.localStorage.getItem(BOLD_TEXT_STORAGE_KEY)).toBe("1");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(document.documentElement.dataset.font).toBe("serif");
    expect(document.documentElement.dataset.boldText).toBe("true");
  });
});
