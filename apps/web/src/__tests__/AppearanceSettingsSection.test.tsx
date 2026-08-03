import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
} from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";

import { AppearanceSettingsSection } from "@/components/Account/AppearanceSettingsSection";
import { AppearanceProvider } from "@/hooks/useAppearance";
import {
  BOLD_TEXT_STORAGE_KEY,
  FONT_STORAGE_KEY,
  THEME_STORAGE_KEY,
} from "@/lib/appearance";

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

beforeEach(() => {
  window.localStorage.removeItem(THEME_STORAGE_KEY);
  window.localStorage.removeItem(FONT_STORAGE_KEY);
  window.localStorage.removeItem(BOLD_TEXT_STORAGE_KEY);
});

afterEach(() => {
  cleanup();
  document.documentElement.classList.remove("dark", "light");
  delete document.documentElement.dataset.theme;
  delete document.documentElement.dataset.computedTheme;
  delete document.documentElement.dataset.font;
  delete document.documentElement.dataset.boldText;
});

describe("AppearanceSettingsSection", () => {
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
